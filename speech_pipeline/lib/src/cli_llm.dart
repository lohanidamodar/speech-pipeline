import 'package:agent_cli/agent_cli.dart';

import 'engines.dart';
import 'thinking_filter.dart';

/// Answers through an AI coding CLI the user already has installed.
///
/// The point is authentication. Someone using `claude` or `codex` daily has
/// already logged in; driving the CLI reuses that, so the assistant works with
/// no API key pasted anywhere and no second subscription.
///
/// What it costs, measured here: 5.5s to the first word through Claude Code
/// and 7.4s through Codex, against 95ms from a local llama.cpp. Every turn is
/// a fresh session that loads the tool list, hooks and project instructions
/// before it answers. For a spoken assistant those seconds are audible
/// silence, so this is the convenient option rather than the fast one.
class CliLlmEngine implements LlmEngine {
  CliLlmEngine(this.agent, {this.model, CliSession? session})
    : _session = session ?? CliSession(agent);

  final CliAgent agent;

  /// Model override, in the CLI's own spelling — `sonnet` for Claude Code.
  final String? model;

  final CliSession _session;

  @override
  Stream<String> respond(List<Message> history) {
    final system = history
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n\n');

    // A CLI hands back whatever the model wrote, reasoning tags included.
    return withoutThinking(_session.ask(
      _renderTranscript(history),
      systemPrompt: system.isEmpty ? null : system,
      model: model,
    ));
  }

  /// Renders the conversation into one prompt.
  ///
  /// Each call is a fresh process, so the history has to travel in the prompt.
  /// The CLIs do have resume modes, but leaning on them would move the
  /// conversation's memory into the CLI's own session store — where the
  /// pipeline cannot trim it, and where it would drift from the history the
  /// caller believes it has.
  static String _renderTranscript(List<Message> history) {
    final turns = history.where((m) => m.role != 'system').toList();
    if (turns.isEmpty) return '';
    if (turns.length == 1) return turns.single.content;

    final buffer = StringBuffer(
      'Continue this conversation. Reply only with your next answer.\n\n',
    );
    for (final message in turns) {
      buffer
        ..write(message.role == 'user' ? 'User: ' : 'Assistant: ')
        ..writeln(message.content);
    }
    buffer.write('Assistant:');
    return buffer.toString();
  }

  @override
  Future<void> dispose() => _session.cancel();
}
