// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:dart2native/generate.dart';
import 'package:front_end/src/api_prototype/compiler_options.dart'
    show Verbosity;
import 'package:path/path.dart' as path;
import 'package:vm/target_os.dart'; // For possible --target-os values.

import '../core.dart';
import '../experiments.dart';
import '../native_assets.dart';
import '../sdk.dart';
import '../utils.dart';

const int compileErrorExitCode = 64;

class Option {
  final String flag;
  final String help;
  final String? abbr;
  final String? defaultsTo;
  final bool? flagDefaultsTo;
  final String? valueHelp;
  final List<String>? allowed;
  final Map<String, String>? allowedHelp;

  const Option({
    required this.flag,
    required this.help,
    this.abbr,
    this.defaultsTo,
    this.flagDefaultsTo,
    this.valueHelp,
    this.allowed,
    this.allowedHelp,
  });
}

bool checkFile(String sourcePath) {
  if (!FileSystemEntity.isFileSync(sourcePath)) {
    stderr.writeln('"$sourcePath" file not found.');
    stderr.flush();
    return false;
  }
  return true;
}

class CompileJSCommand extends CompileSubcommandCommand {
  static const String cmdName = 'js';

  /// Accept all flags so we can delegate arg parsing to dart2js internally.
  @override
  final ArgParser argParser = ArgParser.allowAnything();

  CompileJSCommand({bool verbose = false})
      : super(cmdName, 'Compile Dart to JavaScript.', verbose);

  @override
  String get invocation => '${super.invocation} <dart entry point>';

  @override
  FutureOr<int> run() async {
    if (!Sdk.checkArtifactExists(sdk.dart2jsSnapshot)) return 255;

    final librariesPath = path.absolute(sdk.sdkPath, 'lib', 'libraries.json');

    if (!Sdk.checkArtifactExists(librariesPath)) return 255;

    final args = argResults!;

    // Build arguments.
    final buildArgs = <String>[
      '--libraries-spec=$librariesPath',
      '--cfe-invocation-modes=compile',
      '--invoker=dart_cli',
      // Add the remaining arguments.
      if (args.rest.isNotEmpty) ...args.rest.sublist(0),
    ];

    var retval = 0;
    final result = Completer<int>();
    final exitPort = ReceivePort()
      ..listen((msg) {
        result.complete(0);
      });
    final errorPort = ReceivePort()
      ..listen((error) {
        log.stderr(error.toString());
        result.complete(255);
      });
    try {
      await Isolate.spawnUri(Uri.file(sdk.dart2jsSnapshot), buildArgs, null,
          onExit: exitPort.sendPort, onError: errorPort.sendPort);
      retval = await result.future;
    } catch (e, st) {
      log.stderr('Error: JS compilation failed');
      log.stderr(e.toString());
      if (verbose) {
        log.stderr(st.toString());
      }
      retval = compileErrorExitCode;
    }
    errorPort.close();
    exitPort.close();
    return retval;
  }
}

class CompileSnapshotCommand extends CompileSubcommandCommand {
  static const String jitSnapshotCmdName = 'jit-snapshot';
  static const String kernelCmdName = 'kernel';

  final String commandName;
  final String help;
  final String fileExt;
  final String formatName;

  CompileSnapshotCommand({
    required this.commandName,
    required this.help,
    required this.fileExt,
    required this.formatName,
    bool verbose = false,
  }) : super(commandName, 'Compile Dart $help', verbose) {
    argParser
      ..addOption(
        outputFileOption.flag,
        help: outputFileOption.help,
        abbr: outputFileOption.abbr,
      )
      ..addOption(
        verbosityOption.flag,
        help: verbosityOption.help,
        abbr: verbosityOption.abbr,
        defaultsTo: verbosityOption.defaultsTo,
        allowed: verbosityOption.allowed,
        allowedHelp: verbosityOption.allowedHelp,
      )
      ..addOption(
        packagesOption.flag,
        abbr: packagesOption.abbr,
        valueHelp: packagesOption.valueHelp,
        help: packagesOption.help,
      )
      ..addMultiOption(
        defineOption.flag,
        help: defineOption.help,
        abbr: defineOption.abbr,
        valueHelp: defineOption.valueHelp,
      )
      ..addFlag(soundNullSafetyOption.flag,
          help: soundNullSafetyOption.help,
          defaultsTo: soundNullSafetyOption.flagDefaultsTo,
          hide: true)
      ..addExperimentalFlags(verbose: verbose);
  }

  @override
  String get invocation {
    String msg = '${super.invocation} <dart entry point>';
    if (isJitSnapshot) {
      msg += ' [<training arguments>]';
    }
    return msg;
  }

  @override
  ArgParser createArgParser() {
    return ArgParser(
      // Don't parse the training arguments for JIT snapshots, but don't accept
      // flags after the script name for kernel snapshots.
      allowTrailingOptions: !isJitSnapshot,
      usageLineLength: dartdevUsageLineLength,
    );
  }

  bool get isJitSnapshot => commandName == jitSnapshotCmdName;

  @override
  FutureOr<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      // This throws.
      usageException('Missing Dart entry point.');
    } else if (!isJitSnapshot && args.rest.length > 1) {
      usageException('Unexpected arguments after Dart entry point.');
    }

    final String sourcePath = args.rest[0];
    if (!checkFile(sourcePath)) {
      return -1;
    }

    // Determine output file name.
    String? outputFile = args[outputFileOption.flag];
    if (outputFile == null) {
      final inputWithoutDart = sourcePath.endsWith('.dart')
          ? sourcePath.substring(0, sourcePath.length - 5)
          : sourcePath;
      outputFile = '$inputWithoutDart.$fileExt';
    }

    final enabledExperiments = args.enabledExperiments;
    final defines = args[defineOption.flag] as List<String>;

    // Build arguments.
    final buildArgs = <String>[];
    buildArgs.add('--snapshot-kind=$formatName');
    buildArgs.add('--snapshot=${path.canonicalize(outputFile)}');

    final bool soundNullSafety = args['sound-null-safety'];
    if (!soundNullSafety) {
      if (!shouldAllowNoSoundNullSafety()) {
        return compileErrorExitCode;
      }
      buildArgs.add('--no-sound-null-safety');
    }

    final String? packages = args[packagesOption.flag];
    if (packages != null) {
      buildArgs.add('--packages=$packages');
    }

    final String? verbosity = args[verbosityOption.flag];
    buildArgs.add('--verbosity=$verbosity');

    if (enabledExperiments.isNotEmpty) {
      buildArgs.add("--enable-experiment=${enabledExperiments.join(',')}");
    }
    if (verbose) {
      buildArgs.add('-v');
    }
    for (final define in defines) {
      buildArgs.add('-D$define');
    }
    buildArgs.add(path.canonicalize(sourcePath));

    // Add the training arguments.
    if (args.rest.length > 1) {
      buildArgs.addAll(args.rest.sublist(1));
    }

    log.stdout('Compiling $sourcePath to $commandName file $outputFile.');
    // TODO(bkonyi): perform compilation in same process.
    return await runProcess([sdk.dart, ...buildArgs]);
  }
}

class CompileNativeCommand extends CompileSubcommandCommand {
  static const String exeCmdName = 'exe';
  static const String aotSnapshotCmdName = 'aot-snapshot';

  final String commandName;
  final String format;
  final String help;
  final bool nativeAssetsExperimentEnabled;

  CompileNativeCommand({
    required this.commandName,
    required this.format,
    required this.help,
    bool verbose = false,
    this.nativeAssetsExperimentEnabled = false,
  }) : super(commandName, 'Compile Dart $help', verbose) {
    argParser
      ..addOption(
        outputFileOption.flag,
        help: outputFileOption.help,
        abbr: outputFileOption.abbr,
      )
      ..addOption(
        verbosityOption.flag,
        help: verbosityOption.help,
        abbr: verbosityOption.abbr,
        defaultsTo: verbosityOption.defaultsTo,
        allowed: verbosityOption.allowed,
        allowedHelp: verbosityOption.allowedHelp,
      )
      ..addMultiOption(
        defineOption.flag,
        help: defineOption.help,
        abbr: defineOption.abbr,
        valueHelp: defineOption.valueHelp,
      );
    argParser
      ..addOption(
        packagesOption.flag,
        abbr: packagesOption.abbr,
        valueHelp: packagesOption.valueHelp,
        help: packagesOption.help,
      )
      ..addFlag(soundNullSafetyOption.flag,
          help: soundNullSafetyOption.help,
          defaultsTo: soundNullSafetyOption.flagDefaultsTo,
          hide: true)
      ..addOption('save-debugging-info', abbr: 'S', valueHelp: 'path', help: '''
Remove debugging information from the output and save it separately to the specified file.
<path> can be relative or absolute.''')
      ..addMultiOption(
        'extra-gen-snapshot-options',
        help: 'Pass additional options to gen_snapshot.',
        hide: true,
        valueHelp: 'opt1,opt2,...',
      )
      ..addOption('target-os',
          help: 'Compile to a specific target operating system.',
          allowed: TargetOS.names)
      ..addExperimentalFlags(verbose: verbose);
  }

  @override
  String get invocation => '${super.invocation} <dart entry point>';

  @override
  FutureOr<int> run() async {
    // AOT compilation isn't supported on ia32. Currently, generating an
    // executable only supports AOT runtimes, so these commands are disabled.
    if (Platform.version.contains('ia32')) {
      stderr.write(
          "'dart compile $commandName' is not supported on x86 architectures.\n");
      return 64;
    }
    if (!Sdk.checkArtifactExists(genKernel) ||
        !Sdk.checkArtifactExists(genSnapshot)) {
      return 255;
    }
    final args = argResults!;

    // We expect a single rest argument; the dart entry point.
    if (args.rest.length != 1) {
      // This throws.
      usageException('Missing Dart entry point.');
    }
    final String sourcePath = args.rest[0];
    if (!checkFile(sourcePath)) {
      return -1;
    }

    if (!args['sound-null-safety'] && !shouldAllowNoSoundNullSafety()) {
      return compileErrorExitCode;
    }

    if (!nativeAssetsExperimentEnabled) {
      if (await warnOnNativeAssets()) {
        return 255;
      }
    } else {
      final (success, assets) = await compileNativeAssetsJit(verbose: verbose);
      if (!success) {
        stderr.writeln('Native assets build failed.');
        return 255;
      }
      if (assets.isNotEmpty) {
        stderr.writeln(
            "'dart compile' does currently not support native assets.");
        return 255;
      }
    }

    String? targetOS = args['target-os'];
    if (format != 'exe') {
      assert(format == 'aot');
      // If we're generating an AOT snapshot and not an executable, then
      // targetOS is allowed to be null for a platform-independent snapshot
      // or a different platform than the host.
    } else if (targetOS == null) {
      targetOS = Platform.operatingSystem;
    } else if (targetOS != Platform.operatingSystem) {
      stderr.writeln(
          "'dart compile $commandName' does not support cross-OS compilation.");
      stderr.writeln('Host OS: ${Platform.operatingSystem}');
      stderr.writeln('Target OS: $targetOS');
      return 128;
    }

    try {
      await generateNative(
        kind: format,
        sourceFile: sourcePath,
        outputFile: args['output'],
        defines: args[defineOption.flag],
        packages: args['packages'],
        enableExperiment: args.enabledExperiments.join(','),
        soundNullSafety: args['sound-null-safety'],
        debugFile: args['save-debugging-info'],
        verbose: verbose,
        verbosity: args['verbosity'],
        extraOptions: args['extra-gen-snapshot-options'],
        targetOS: targetOS,
      );
      return 0;
    } catch (e, st) {
      log.stderr('Error: AOT compilation failed');
      log.stderr(e.toString());
      if (verbose) {
        log.stderr(st.toString());
      }
      return compileErrorExitCode;
    }
  }
}

class CompileWasmCommand extends CompileSubcommandCommand {
  static const String commandName = 'wasm';
  static const String format = 'wasm';
  static const String help =
      'Compile Dart to a WebAssembly/WasmGC module (EXPERIMENTAL).';

  // The unique place where we store various flags for dart2wasm & binaryen.
  //
  // Other uses (e.g. pkg/dart2wasm/tool/compile_benchmark) will grep in this
  // file for the flags. So please keep the formatting.

  final List<String> binaryenFlags = _flagList('''
      --all-features
      --closed-world
      --traps-never-happen
      --type-unfinalizing
      -O3
      --type-ssa
      --gufa
      -O3
      --type-merging
      -O1
      --type-finalizing
    '''); // end of binaryenFlags

  final List<String> optimizationLevel0Flags = _flagList('''
      --no-inlining
    '''); // end of optimizationLevel0Flags

  final List<String> optimizationLevel1Flags = _flagList('''
      --inlining
    '''); // end of optimizationLevel1Flags

  final List<String> optimizationLevel2Flags = _flagList('''
      --inlining
      --minify
    '''); // end of optimizationLevel2Flags

  final List<String> optimizationLevel3Flags = _flagList('''
      --inlining
      --minify
      --omit-implicit-checks
    '''); // end of optimizationLevel3Flags

  final List<String> optimizationLevel4Flags = _flagList('''
      --inlining
      --minify
      --omit-implicit-checks
      --omit-explicit-checks
    '''); // end of optimizationLevel4Flags

  static List<String> _flagList(String lines) => lines
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  CompileWasmCommand({bool verbose = false})
      : super(commandName, help, verbose, hidden: !verbose) {
    argParser
      ..addOption(
        outputFileOption.flag,
        help: outputFileOption.help,
        abbr: outputFileOption.abbr,
      )
      ..addFlag(
        'minify',
        defaultsTo: false,
        negatable: true,
        help: 'Generate minified output.',
        hide: !verbose,
      )
      ..addFlag(
        'name-section',
        defaultsTo: false,
        negatable: false,
        help: 'Include a name section with printable function names.',
        hide: !verbose,
      )
      ..addFlag(
        'print-wasm',
        help: 'Print human-readable wasm debug output',
        hide: !verbose,
        negatable: false,
      )
      ..addFlag(
        'print-kernel',
        help: 'Print human-readable Dart kernel debug output',
        hide: !verbose,
        negatable: false,
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Print debug output during compilation',
        negatable: false,
      )
      ..addFlag(
        'enable-asserts',
        help: 'Enable assert statements.',
        negatable: false,
      )
      ..addOption(
        'shared-memory',
        help: 'Import a shared memory buffer.'
            ' The max number of pages must be passed.',
        valueHelp: 'page count',
        hide: !verbose,
      )
      ..addOption(
        'optimization-level',
        abbr: 'O',
        help: 'Controls optimizations that can help reduce code-size and '
            'improve performance of the generated code.',
        allowed: ['0', '1', '2', '3', '4'],
        defaultsTo: '1',
        valueHelp: 'level',
        hide: !verbose,
      )
      ..addOption(
        packagesOption.flag,
        abbr: packagesOption.abbr,
        valueHelp: packagesOption.valueHelp,
        help: packagesOption.help,
        hide: !verbose,
      )
      ..addMultiOption(
        defineOption.flag,
        help: defineOption.help,
        abbr: defineOption.abbr,
        valueHelp: defineOption.valueHelp,
      );
  }

  @override
  String get invocation => '${super.invocation} <dart entry point>';

  @override
  FutureOr<int> run() async {
    log.stdout('*NOTE*: Compilation to WasmGC is experimental.');
    log.stdout(
        'The support may change, or be removed, with no advance notice.\n');

    final args = argResults!;
    final verbose = this.verbose || args['verbose'];

    if (!Sdk.checkArtifactExists(sdk.librariesJson) ||
        !Sdk.checkArtifactExists(sdk.dartAotRuntime) ||
        !Sdk.checkArtifactExists(sdk.dart2wasmSnapshot) ||
        !Sdk.checkArtifactExists(sdk.wasmOpt)) {
      return 255;
    }

    // We expect a single rest argument; the dart entry point.
    if (args.rest.length != 1) {
      // This throws.
      usageException('Missing Dart entry point.');
    }
    final String sourcePath = args.rest[0];
    if (!checkFile(sourcePath)) {
      return -1;
    }

    // Determine output file name.
    String? outputFile = args[outputFileOption.flag];
    if (outputFile == null) {
      final inputWithoutDart = sourcePath.endsWith('.dart')
          ? sourcePath.substring(0, sourcePath.length - 5)
          : sourcePath;
      outputFile = '$inputWithoutDart.wasm';
    }

    if (!outputFile.endsWith('.wasm')) {
      log.stderr(
          'Error: The output file "$outputFile" does not end with ".wasm"');
      return 255;
    }
    final outputFileBasename =
        outputFile.substring(0, outputFile.length - '.wasm'.length);

    final sdkPath = path.absolute(sdk.sdkPath);
    final packages = args[packagesOption.flag];
    final defines = args[defineOption.flag] as List<String>;

    int? maxPages;
    if (args['shared-memory'] != null) {
      maxPages = int.tryParse(args['shared-memory']);
      if (maxPages == null) {
        usageException(
            'Error: The --shared-memory flag must specify a number!');
      }
    }

    final optimizationLevel = int.parse(args['optimization-level']);
    final runWasmOpt = optimizationLevel >= 1;

    final dart2wasmCommand = [
      sdk.dartAotRuntime,
      sdk.dart2wasmSnapshot,

      '--libraries-spec=${sdk.librariesJson}',
      '--dart-sdk=$sdkPath',
      if (verbose) '--verbose',
      if (packages != null) '--packages=$packages',
      if (args['print-wasm']) '--print-wasm',
      if (args['print-kernel']) '--print-kernel',
      if (args['enable-asserts']) '--enable-asserts',
      for (final define in defines) '-D$define',
      if (maxPages != null) ...[
        '--import-shared-memory',
        '--shared-memory-max-pages=$maxPages',
      ],

      // First we pass flags based on the optimization level.
      ...switch (optimizationLevel) {
        0 => optimizationLevel0Flags,
        1 => optimizationLevel1Flags,
        2 => optimizationLevel2Flags,
        3 => optimizationLevel3Flags,
        4 => optimizationLevel4Flags,
        _ => throw 'unreachable',
      },
      // Then we pass flags that were opted into explicitly.
      if (args['name-section']) '--name-section',
      if (args['minify']) '--minify',

      path.absolute(sourcePath),
      outputFile,
    ];
    try {
      final exitCode = await runProcess(dart2wasmCommand);
      if (exitCode != 0) return compileErrorExitCode;
    } catch (e, st) {
      log.stderr('Error: Wasm compilation failed');
      log.stderr(e.toString());
      if (verbose) {
        log.stderr(st.toString());
      }
      return compileErrorExitCode;
    }

    if (runWasmOpt) {
      final unoptFile = '$outputFileBasename.unopt.wasm';
      File(outputFile).renameSync(unoptFile);

      final flags = [
        ...binaryenFlags,
        if (args['name-section']) '-g',
      ];

      if (verbose) {
        log.stdout('Optimizing output with: ${sdk.wasmOpt} $flags');
      }
      final processResult = Process.runSync(
        sdk.wasmOpt,
        [...flags, '-o', outputFile, unoptFile],
      );
      if (processResult.exitCode != 0) {
        log.stderr('Error: Wasm compilation failed while optimizing output');
        log.stderr(processResult.stderr);
        return compileErrorExitCode;
      }
    }

    final mjsFile = '$outputFileBasename.mjs';
    log.stdout(
        "Generated wasm module '$outputFile', and JS init file '$mjsFile'.");
    return 0;
  }
}

abstract class CompileSubcommandCommand extends DartdevCommand {
  final outputFileOption = Option(
    flag: 'output',
    abbr: 'o',
    help: '''
Write the output to <file name>.
This can be an absolute or relative path.
''',
  );
  final verbosityOption = Option(
    flag: 'verbosity',
    help: '''
Sets the verbosity level of the compilation.
''',
    defaultsTo: Verbosity.defaultValue,
    allowed: Verbosity.allowedValues,
    allowedHelp: Verbosity.allowedValuesHelp,
  );
  final soundNullSafetyOption = Option(
    flag: 'sound-null-safety',
    help: 'DEPRECATED: Respect the nullability of types at runtime.',
    flagDefaultsTo: true,
  );

  late final Option defineOption;
  late final Option packagesOption;

  CompileSubcommandCommand(super.name, super.description, super.verbose,
      {super.hidden})
      : defineOption = Option(
          flag: 'define',
          abbr: 'D',
          valueHelp: 'key=value',
          help: '''
Define an environment declaration. To specify multiple declarations, use multiple options or use commas to separate key-value pairs.
For example: dart compile $name -Da=1,b=2 main.dart''',
        ),
        packagesOption = Option(
            flag: 'packages',
            abbr: 'p',
            valueHelp: 'path',
            help:
                '''Get package locations from the specified file instead of .dart_tool/package_config.json.
<path> can be relative or absolute.
For example: dart compile $name --packages=/tmp/pkgs.json main.dart''');

  bool shouldAllowNoSoundNullSafety() {
    // We need to maintain support for generating AOT snapshots and kernel
    // files with no-sound-null-safety internal Flutter aplications are
    // fully null-safe.
    //
    // See https://github.com/dart-lang/sdk/issues/51513 for context.
    if (name == CompileNativeCommand.aotSnapshotCmdName ||
        name == CompileSnapshotCommand.kernelCmdName) {
      log.stdout(
          'Warning: the flag --no-sound-null-safety is deprecated and pending removal.');
      return true;
    }
    log.stdout(
        'Error: the flag --no-sound-null-safety is not supported in Dart 3.');
    return false;
  }
}

class CompileCommand extends DartdevCommand {
  static const String cmdName = 'compile';
  CompileCommand({
    bool verbose = false,
    bool nativeAssetsExperimentEnabled = false,
  }) : super(cmdName, 'Compile Dart to various formats.', verbose) {
    addSubcommand(CompileJSCommand(verbose: verbose));
    addSubcommand(CompileSnapshotCommand(
      commandName: CompileSnapshotCommand.jitSnapshotCmdName,
      help: 'to a JIT snapshot.\n'
          'The executable will be run once to snapshot a warm JIT.\n'
          'To run the snapshot use: dart run <JIT file>',
      fileExt: 'jit',
      formatName: 'app-jit',
      verbose: verbose,
    ));
    addSubcommand(CompileSnapshotCommand(
      commandName: CompileSnapshotCommand.kernelCmdName,
      help: 'to a kernel snapshot.\n'
          'To run the snapshot use: dart run <kernel file>',
      fileExt: 'dill',
      formatName: 'kernel',
      verbose: verbose,
    ));
    addSubcommand(CompileNativeCommand(
      commandName: CompileNativeCommand.exeCmdName,
      help: 'to a self-contained executable.',
      format: 'exe',
      verbose: verbose,
      nativeAssetsExperimentEnabled: nativeAssetsExperimentEnabled,
    ));
    addSubcommand(CompileNativeCommand(
      commandName: CompileNativeCommand.aotSnapshotCmdName,
      help: 'to an AOT snapshot.\n'
          'To run the snapshot use: dartaotruntime <AOT snapshot file>',
      format: 'aot',
      verbose: verbose,
      nativeAssetsExperimentEnabled: nativeAssetsExperimentEnabled,
    ));
    addSubcommand(CompileWasmCommand(verbose: verbose));
  }
}
