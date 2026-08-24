import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'engines.dart';
import 'openai_llm.dart' show LlmException, LlmUnreachable;

/// Streaming client for Anthropic's Messages API.
///
/// Anthropic is the one provider here that is not OpenAI-shaped: the system
/// prompt is a top-level field rather than a message, `max_tokens` is required,
/// and the stream is a typed event sequence instead of chat deltas.
class AnthropicLlm implements LlmEngine {
  AnthropicLlm({
    required this.apiKey,
    this.model = 'claude-sonnet-4-6',
    this.baseUrl = 'https://api.anthropic.com/v1',
    this.temperature = 0.7,
    this.maxTokens = 512,
    this.version = '2023-06-01',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final String baseUrl;
  final double temperature;
  final int maxTokens;
  final String version;

  final http.Client _client;

  @override
  Stream<String> respond(List<Message> history) async* {
    // System turns are hoisted out; the API rejects them inside `messages`.
    final system = history
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n\n');
    final turns = history.where((m) => m.role != 'system').toList();

    final request = http.Request('POST', Uri.parse('$baseUrl/messages'))
      ..headers.addAll({
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': version,
      })
      ..body = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'stream': true,
        if (system.isNotEmpty) 'system': system,
        'messages': [for (final m in turns) m.toJson()],
      });

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
      throw LlmException(
        response.statusCode,
        await response.stream.bytesToString(),
      );
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final delta = _textDelta(line.substring(5).trim());
      if (delta != null && delta.isNotEmpty) yield delta;
    }
  }

  /// Extracts spoken text from one event.
  ///
  /// `thinking_delta` blocks are skipped for the same reason `reasoning_content`
  /// is elsewhere: a voice assistant must not read its own scratchpad aloud.
  static String? _textDelta(String payload) {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      if (json['type'] == 'error') {
        final error = json['error'] as Map<String, dynamic>?;
        throw LlmException(200, '${error?['type']}: ${error?['message']}');
      }
      if (json['type'] != 'content_block_delta') return null;
      final delta = json['delta'] as Map<String, dynamic>?;
      if (delta?['type'] != 'text_delta') return null;
      return delta?['text'] as String?;
    } on FormatException {
      return null; // keep-alive frames
    }
  }

  @override
  Future<void> dispose() async => _client.close();
}
