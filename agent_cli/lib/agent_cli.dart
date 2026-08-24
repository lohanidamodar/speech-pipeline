/// Discovers and drives already-installed AI coding CLIs.
///
/// The process layer follows the design proven in chitragupta-app: one
/// `CommandRunner` abstraction with a native and a WSL implementation, and
/// lookups through a login shell so CLIs installed in `~/.local/bin` are
/// actually found.
library;

export 'src/cli_agent.dart';
export 'src/cli_discovery.dart';
export 'src/cli_session.dart';
export 'src/command_runner.dart';
export 'src/io_process_handle.dart';
export 'src/runners.dart';
