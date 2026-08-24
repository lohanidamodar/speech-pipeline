import 'dart:convert';

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
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String model;
  final String? apiKey;
  final double temperature;
  final int maxTokens;
  final http.Client _client;

  @override
  Stream<String> respond(List<Message> history) async* {
    final request =
        http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode({
            'model': model,
            'messages': [for (final m in history) m.toJson()],
            'temperature': temperature,
            'max_tokens': maxTokens,
            'stream': true,
          });
    if (apiKey != null) {
      request.headers['authorization'] = 'Bearer $apiKey';
    }

    final response = await _client.send(request);
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

  static String? _contentDelta(String payload) {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;
      final delta = (choices.first as Map<String, dynamic>)['delta'];
      return (delta as Map<String, dynamic>?)?['content'] as String?;
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
