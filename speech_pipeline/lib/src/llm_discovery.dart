import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_providers.dart';

/// A local OpenAI-compatible server that answered a probe.
class DiscoveredServer {
  const DiscoveredServer({
    required this.baseUrl,
    required this.providerId,
    required this.models,
  });

  final String baseUrl;

  /// The catalog entry this address belongs to, so selecting it configures the
  /// right transport rather than always falling back to `custom`.
  final String providerId;

  /// Model ids the server reports. Empty when it answered but listed none.
  final List<String> models;

  String get label =>
      llmProviderById(providerId)?.label ?? 'OpenAI-compatible server';

  @override
  String toString() =>
      '$label at $baseUrl'
      '${models.isEmpty ? '' : ' · ${models.length} model(s)'}';
}

/// Addresses worth probing, in the order a user is likeliest to be running.
///
/// Ports rather than a range: scanning arbitrary ports on someone's machine is
/// both slow and rude, and these are the defaults the three common servers
/// ship with. 8081 and 8082 are here because running a second llama.cpp beside
/// the first is routine, and getting the port wrong is the single most common
/// reason the assistant cannot reach a model.
const defaultLocalEndpoints = <(String, String)>[
  ('llamacpp', 'http://127.0.0.1:8080/v1'),
  ('llamacpp', 'http://127.0.0.1:8081/v1'),
  ('llamacpp', 'http://127.0.0.1:8082/v1'),
  ('ollama', 'http://127.0.0.1:11434/v1'),
  ('custom', 'http://127.0.0.1:1234/v1'), // LM Studio
  ('custom', 'http://127.0.0.1:5000/v1'), // text-generation-webui
];

/// Probes local addresses and returns the ones serving models.
///
/// `/v1/models` is the probe because every OpenAI-compatible server implements
/// it, it needs no authentication on a local server, and its answer names the
/// model — which is the other thing the user would otherwise have to type
/// exactly right.
Future<List<DiscoveredServer>> discoverLocalLlms({
  List<(String, String)> endpoints = defaultLocalEndpoints,
  Duration timeout = const Duration(milliseconds: 700),
  http.Client? client,
}) async {
  final owned = client == null;
  final http$ = client ?? http.Client();

  try {
    // Probed together: a closed port refuses immediately, an open one answers
    // in milliseconds, and doing six in sequence would still feel slow.
    final results = await Future.wait([
      for (final (providerId, baseUrl) in endpoints)
        _probe(http$, providerId, baseUrl, timeout),
    ]);
    return results.whereType<DiscoveredServer>().toList();
  } finally {
    if (owned) http$.close();
  }
}

Future<DiscoveredServer?> _probe(
  http.Client client,
  String providerId,
  String baseUrl,
  Duration timeout,
) async {
  try {
    final response = await client
        .get(Uri.parse('$baseUrl/models'))
        .timeout(timeout);
    if (response.statusCode != 200) return null;

    final json = jsonDecode(response.body);
    final data = json is Map<String, dynamic> ? json['data'] : null;
    final models = <String>[
      if (data is List)
        for (final entry in data)
          if (entry is Map<String, dynamic> && entry['id'] is String)
            entry['id'] as String,
    ];
    return DiscoveredServer(
      baseUrl: baseUrl,
      providerId: providerId,
      models: models,
    );
  } catch (_) {
    // Nothing listening, not OpenAI-compatible, or too slow to be worth
    // offering. All of them mean the same thing here: not a usable server.
    return null;
  }
}
