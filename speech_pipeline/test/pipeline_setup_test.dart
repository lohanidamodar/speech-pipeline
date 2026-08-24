import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('llmConfigFromEnvironment', () {
    test('defaults to OpenAI when nothing is set', () {
      final cfg = llmConfigFromEnvironment(const {});
      expect(cfg.provider.id, 'openai');
      expect(cfg.isConfigured, isFalse, reason: 'no key yet');
    });

    test('a bare base URL still means a local server, as it always did', () {
      // The original knob, from when llama.cpp was the only target. Anyone with
      // it in a shell profile must keep working without adding a provider name.
      final cfg = llmConfigFromEnvironment(const {
        'SP_LLM_BASE_URL': 'http://127.0.0.1:8081/v1',
        'SP_LLM_MODEL': 'qwen3',
      });
      expect(cfg.provider.id, 'custom');
      expect(cfg.isConfigured, isTrue, reason: 'no API key should be needed');
      expect(cfg.effectiveBaseUrl, 'http://127.0.0.1:8081/v1');
    });

    test('a named provider supplies its own defaults', () {
      final cfg = llmConfigFromEnvironment(const {'SP_LLM_PROVIDER': 'ollama'});
      expect(cfg.effectiveBaseUrl, 'http://127.0.0.1:11434/v1');
      expect(cfg.effectiveModel, 'qwen3:1.7b');
      expect(cfg.provider.isPrivate, isTrue);
    });

    test('overrides beat the provider defaults', () {
      final cfg = llmConfigFromEnvironment(const {
        'SP_LLM_PROVIDER': 'openrouter',
        'SP_LLM_MODEL': 'anthropic/claude-sonnet-4-6',
        'SP_LLM_API_KEY': 'sk-test',
        'SP_LLM_MAX_TOKENS': '128',
      });
      expect(cfg.effectiveModel, 'anthropic/claude-sonnet-4-6');
      expect(cfg.maxTokens, 128);
      expect(buildLlm(cfg), isA<OpenAiCompatibleLlm>());
    });

    test('rejects an unknown provider by name, listing the real ones', () {
      expect(
        () => llmConfigFromEnvironment(const {'SP_LLM_PROVIDER': 'gpt5'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('openrouter'),
          ),
        ),
      );
    });

    test(
      'ignores an unparseable token budget rather than failing to start',
      () {
        expect(
          llmConfigFromEnvironment(const {
            'SP_LLM_MAX_TOKENS': 'lots',
          }).maxTokens,
          512,
        );
      },
    );
  });
}
