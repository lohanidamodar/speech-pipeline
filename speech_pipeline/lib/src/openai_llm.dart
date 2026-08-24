import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'engines.dart';

/// Streaming client for any OpenAI-compatible `/chat/completions` endpoint —
/// the Anthropic-compatible gateways, Ollama, llama.cpp's server, vLLM, Groq.
///
/// Cancelling the returned stream drops the HTTP response, which is what stops
/// token generation when the user interrupts.
class OpenAiCompatibleLlm implements LlmEngine {
  OpenAiCompatibleLlm({
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.temperature = 0.7,
    this.maxTokens = 512,
    this.disableThinking = false,
    this.extraHeaders = const {},
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String model;
  final String? apiKey;
  final double temperature;
  final int maxTokens;

  /// Reasoning models (Qwen3, DeepSeek-R1 and kin) emit a long
  /// `reasoning_content` stream before any answer. For a spoken assistant that
  /// is dead air, and with a modest token budget the reply never arrives at
  /// all — the whole allowance goes on thinking and the turn ends on
  /// `finish_reason: length`.
  ///
  /// The knobs used to suppress it are llama.cpp and vLLM extensions, and a
  /// strict OpenAI-compatible API rejects unrecognised request fields — so this
  /// defaults to off and [buildLlm] turns it on only for the providers that
  /// accept it. The reasoning channel is never yielded either way.
  final bool disableThinking;

  /// Provider-specific headers — OpenRouter's attribution pair, for instance.
  final Map<String, String> extraHeaders;

  final http.Client _client;

  @override
  Stream<String> respond(List<Message> history) async* {
    final request = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'messages': [for (final m in history) m.toJson()],
        'temperature': temperature,
        'max_tokens': maxTokens,
        'stream': true,
        // llama.cpp and vLLM spell this differently; sending both is
        // harmless to servers that understand neither.
        if (disableThinking) ...{
          'reasoning_effort': 'none',
          'chat_template_kwargs': {'enable_thinking': false},
        },
      });
    request.headers.addAll(extraHeaders);
    if (apiKey != null && apiKey!.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $apiKey';
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } on http.ClientException catch (e) {
      throw LlmUnreachable(baseUrl, e.message);
    } on SocketException catch (e) {
      throw LlmUnreachable(baseUrl, e.message);
    } on TimeoutException {
      throw LlmUnreachable(baseUrl, 'timed out');
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(response.statusCode, body);
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;

      final delta = _contentDelta(payload);
      if (delta != null && delta.isNotEmpty) yield delta;
    }
  }

  /// Pulls the spoken text out of one SSE frame.
  ///
  /// `reasoning_content` is deliberately ignored rather than concatenated:
  /// it is the model's scratchpad, not something to read aloud.
  static String? _contentDelta(String payload) {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>?;
      // Streaming frames carry `delta`; a non-streaming reply carries
      // `message`, and some proxies fall back to it mid-stream.
      final message = choice['message'] as Map<String, dynamic>?;
      return (delta?['content'] ?? message?['content']) as String?;
    } on FormatException {
      return null; // keep-alive comments and partial frames
    }
  }

  @override
  Future<void> dispose() async => _client.close();
}

class LlmException implements Exception {
  LlmException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'LlmException($statusCode): $body';
}

/// The server could not be reached at all.
///
/// Separate from [LlmException] because the fix is different in kind: nothing
/// answered, so there is no status code and no response body to read. The
/// underlying `ClientException: Connection refused` names neither the address
/// tried nor anything the user can act on, which is exactly what they need.
class LlmUnreachable implements Exception {
  LlmUnreachable(this.baseUrl, this.detail);

  final String baseUrl;
  final String detail;

  @override
  String toString() =>
      'Could not reach $baseUrl — is the server running? '
      '($detail)';
}
