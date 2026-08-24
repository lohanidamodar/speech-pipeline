import 'anthropic_llm.dart';
import 'engines.dart';
import 'openai_llm.dart';

/// How a provider is spoken to on the wire.
enum LlmTransport { openAiCompatible, anthropic }

/// Where the model actually runs — the distinction that decides whether a
/// conversation leaves the device.
enum LlmLocality {
  /// In this process, or on this machine.
  onDevice,

  /// A server the user runs (llama.cpp, Ollama, LM Studio) reachable over the
  /// network. Private, but not offline.
  selfHosted,

  /// A third-party API. Audio never leaves the device — the pipeline only ever
  /// sends the transcript — but that transcript does.
  cloud,
}

/// One selectable LLM backend.
///
/// Data rather than a switch statement: adding a provider is a list entry, and
/// every field a caller might branch on is answerable without a code path.
class LlmProvider {
  const LlmProvider({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
    this.transport = LlmTransport.openAiCompatible,
    this.locality = LlmLocality.cloud,
    this.needsApiKey = true,
    this.needsBaseUrl = false,
    this.thinkingToggle = false,
    this.extraHeaders = const {},
  });

  final String id;
  final String label;
  final String baseUrl;
  final String defaultModel;
  final LlmTransport transport;
  final LlmLocality locality;

  /// False for local servers, which authenticate nothing.
  final bool needsApiKey;

  /// True when [baseUrl] is only a placeholder the user must replace.
  final bool needsBaseUrl;

  /// Whether this provider understands `reasoning_effort` and
  /// `chat_template_kwargs`.
  ///
  /// These are llama.cpp and vLLM extensions. A strict OpenAI-compatible API
  /// rejects request fields it does not recognise, so sending them everywhere
  /// would turn a working cloud call into a 400. Only servers known to accept
  /// them get them — which is also where the problem actually lives, since the
  /// small reasoning models are the ones people self-host.
  final bool thinkingToggle;

  final Map<String, String> extraHeaders;

  bool get isPrivate => locality != LlmLocality.cloud;
}

/// The built-in catalog. Mirrors the provider set diyo offers so a user moving
/// between the two apps meets the same names and the same keys.
const llmProviders = <LlmProvider>[
  LlmProvider(
    id: 'llamacpp',
    thinkingToggle: true,
    label: 'llama.cpp (local)',
    baseUrl: 'http://127.0.0.1:8080/v1',
    defaultModel: 'local',
    locality: LlmLocality.selfHosted,
    needsApiKey: false,
  ),
  LlmProvider(
    id: 'ollama',
    thinkingToggle: true,
    label: 'Ollama (local)',
    baseUrl: 'http://127.0.0.1:11434/v1',
    defaultModel: 'qwen3:1.7b',
    locality: LlmLocality.selfHosted,
    needsApiKey: false,
  ),
  LlmProvider(
    id: 'openai',
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  ),
  LlmProvider(
    id: 'anthropic',
    label: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4-6',
    transport: LlmTransport.anthropic,
  ),
  // Google exposes an OpenAI-compatible surface beside its native API; using
  // it keeps Gemini on the same transport as everything else here.
  LlmProvider(
    id: 'gemini',
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-2.5-flash',
  ),
  LlmProvider(
    id: 'kimi',
    label: 'Kimi (Moonshot)',
    baseUrl: 'https://api.moonshot.ai/v1',
    defaultModel: 'kimi-k2.6',
  ),
  LlmProvider(
    id: 'openrouter',
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
    extraHeaders: {'X-Title': 'Speech Pipeline'},
  ),
  LlmProvider(
    id: 'deepseek',
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
  ),
  LlmProvider(
    id: 'groq',
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile',
  ),
  LlmProvider(
    id: 'nvidia',
    label: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    defaultModel: 'meta/llama-3.1-8b-instruct',
  ),
  // No key required: a hand-entered endpoint is usually the user's own
  // server, and those authenticate nothing. Locality stays `cloud` because we
  // cannot tell — claiming privacy we haven't verified is the worse error.
  LlmProvider(
    id: 'custom',
    label: 'Custom (OpenAI-compatible)',
    baseUrl: '',
    defaultModel: '',
    needsApiKey: false,
    needsBaseUrl: true,
    thinkingToggle: true,
  ),
];

LlmProvider? llmProviderById(String id) {
  for (final p in llmProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// A chosen provider plus the settings the user filled in for it.
class LlmConfig {
  const LlmConfig({
    required this.provider,
    this.model,
    this.apiKey,
    this.baseUrl,
    this.temperature = 0.7,
    this.maxTokens = 512,
  });

  final LlmProvider provider;

  /// Overrides for what the provider defaults to.
  final String? model;
  final String? apiKey;
  final String? baseUrl;

  final double temperature;
  final int maxTokens;

  String get effectiveModel =>
      (model ?? '').isNotEmpty ? model! : provider.defaultModel;

  String get effectiveBaseUrl {
    final url = (baseUrl ?? '').isNotEmpty ? baseUrl! : provider.baseUrl;
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  /// Why this config cannot be used yet, or null when it is ready.
  ///
  /// Returned rather than thrown: a settings screen wants to show this next to
  /// the field, not catch it.
  String? get problem {
    if (provider.needsApiKey && (apiKey ?? '').isEmpty) {
      return '${provider.label} needs an API key.';
    }
    if (effectiveBaseUrl.isEmpty) return '${provider.label} needs a base URL.';
    if (effectiveModel.isEmpty) return '${provider.label} needs a model name.';
    return null;
  }

  bool get isConfigured => problem == null;
}

/// Builds the engine for [config].
///
/// Throws [StateError] rather than returning a half-configured engine that
/// would fail later, mid-conversation, as an opaque HTTP error.
LlmEngine buildLlm(LlmConfig config) {
  if (config.problem case final problem?) throw StateError(problem);

  return switch (config.provider.transport) {
    LlmTransport.anthropic => AnthropicLlm(
      apiKey: config.apiKey!,
      model: config.effectiveModel,
      baseUrl: config.effectiveBaseUrl,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
    ),
    LlmTransport.openAiCompatible => OpenAiCompatibleLlm(
      baseUrl: config.effectiveBaseUrl,
      model: config.effectiveModel,
      apiKey: config.apiKey,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
      disableThinking: config.provider.thinkingToggle,
      extraHeaders: config.provider.extraHeaders,
    ),
  };
}
