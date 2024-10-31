// Copyright (c) 2024. the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:vm_service/vm_service_io.dart' as vm_service;

String prefixLines(String lines, {required String prefix}) {
  return lines.split('\n').map((l) => '$prefix$l').join('\n');
}

Future<String> execute(String command,
    [List<String> arguments = const <String>[]]) async {
  final result = await Process.run(command, arguments);
  if (result.exitCode != 0) {
    stderr.writeln(
        'running $command ${arguments.join(' ')} failed with ${result.exitCode}');
    stderr.writeln(prefixLines(prefix: 'stdout', result.stdout as String));
    stderr.writeln(prefixLines(prefix: 'stderr', result.stderr as String));
    exit(1);
  }
  return result.stdout as String;
}

Future<Map<int, String>> getProcesses() async {
  final output = await execute('ps', ['xo', 'pid=,command=']);
  return Map.fromEntries(output
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) {
    final spacePos = line.indexOf(' ');
    final pid = line.substring(0, spacePos);
    final command = line.substring(spacePos + 1);
    return MapEntry(int.parse(pid), command);
  }));
}

Future<Map<int, String>> getDartProcesses(String kind) async {
  final allProcesses = await getProcesses();
  final filter = 'dart $kind';
  return {
    for (var e in allProcesses.entries)
      if (e.value.contains(filter)) e.key: e.value,
  };
}

Future<Map<int, String>> getDartLspProcesses() async {
  return await getDartProcesses('language-server');
}

Future<Map<int, String>> getDartDDSProcesses() async {
  return await getDartProcesses('development-service');
}

Future<Map<int, int>> getPortToPidMapping() async {
  final output = await execute('lsof', ['-iTCP', '-sTCP:LISTEN', '-Fpn']);
  late int currentPid;
  final result = <int, int>{};
  for (var line in output.split('\n')) {
    if (line.startsWith('p')) {
      currentPid = int.parse(line.substring(1));
    } else if (line.startsWith('nlocalhost:')) {
      if (int.tryParse(line.substring('nlocalhost:'.length)) case final port?) {
        result[port] = currentPid;
      }
    }
  }
  return result;
}

void printProcesses<V>(Map<int, V> processes) {
  for (var entry in processes.entries) {
    print(' | ${entry.key} ${entry.value}');
  }
  print('');
}

extension<K, V> on Map<K, V> {
  Map<V, List<K>> get inverted {
    final result = <V, List<K>>{};
    for (var entry in this.entries) {
      result.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    return result;
  }
}

Future<Map<int, Uri>> getVmServiceUris(Map<int, String> lspProcesses) async {
  final result = <int, Uri>{};
  print('Finding all open ports');
  final portToPid = await getPortToPidMapping();
  print('-> Ports open by LSP processes:');
  printProcesses({
    for (var entry in portToPid.inverted.entries)
      if (lspProcesses.containsKey(entry.key)) entry.key: entry.value,
  });

  print('Checking for development-service processes');
  final ddsProcesses = await getDartDDSProcesses();
  printProcesses(ddsProcesses);

  for (var dds in ddsProcesses.entries) {
    final vmServiceUriString = dds.value
        .split(' ')
        .firstWhereOrNull((arg) => arg.startsWith('--vm-service-uri='))
        ?.substring('--vm-service-uri='.length);
    final vmServiceUri =
        vmServiceUriString != null ? Uri.tryParse(vmServiceUriString) : null;
    if (vmServiceUri == null) {
      print(
          'Unable to determine VM Service URI from DDS process: ${dds.value}');
      continue;
    }
    if (portToPid[vmServiceUri.port] case final targetPid?
        when lspProcesses.containsKey(targetPid)) {
      result[targetPid] = vmServiceUri.replace(scheme: 'ws').resolve('ws');
    }
  }
  return result;
}

Future<Map<String, dynamic>> collectDataFrom(Uri serviceUri) async {
  Map<String, dynamic> collectedData = {};
  var serviceClient =
      await vm_service.vmServiceConnectUri(serviceUri.toString());
  try {
    var vm = await serviceClient.getVM();
    collectedData['vm.architectureBits'] = vm.architectureBits;
    collectedData['vm.hostCPU'] = vm.hostCPU;
    collectedData['vm.operatingSystem'] = vm.operatingSystem;
    collectedData['vm.startTime'] = vm.startTime;

    var processMemoryUsage = await serviceClient.getProcessMemoryUsage();
    collectedData['processMemoryUsage'] = processMemoryUsage.json;

    var isolateData = [];
    collectedData['isolates'] = isolateData;
    var isolates = [...?vm.isolates, ...?vm.systemIsolates];
    for (var isolate in isolates) {
      if (isolate.name == 'vm-service' ||
          isolate.name == 'kernel-service' ||
          isolate.name == 'dartdev') {
        continue;
      }
      String? id = isolate.id;
      if (id == null) continue;
      var thisIsolateData = {};
      isolateData.add(thisIsolateData);
      thisIsolateData['id'] = id;
      thisIsolateData['isolateGroupId'] = isolate.isolateGroupId;
      thisIsolateData['name'] = isolate.name;
      var isolateMemoryUsage = await serviceClient.getMemoryUsage(id);
      thisIsolateData['memory'] = isolateMemoryUsage.json;
      var allocationProfile = await serviceClient.getAllocationProfile(id);
      var allocationMembers = allocationProfile.members ?? [];
      var allocationProfileData = [];
      thisIsolateData['allocationProfile'] = allocationProfileData;
      for (var member in allocationMembers) {
        var bytesCurrent = member.bytesCurrent;
        // Filter out very small entries to avoid the report becoming too big.
        if (bytesCurrent == null || bytesCurrent < 1024) continue;

        var memberData = {};
        allocationProfileData.add(memberData);
        memberData['bytesCurrent'] = bytesCurrent;
        memberData['instancesCurrent'] = member.instancesCurrent;
        memberData['accumulatedSize'] = member.accumulatedSize;
        memberData['instancesAccumulated'] = member.instancesAccumulated;
        memberData['className'] = member.classRef?.name;
        memberData['libraryName'] = member.classRef?.library?.name;
      }
      allocationProfileData.sort((a, b) {
        int bytesCurrentA = a['bytesCurrent'] as int;
        int bytesCurrentB = b['bytesCurrent'] as int;
        // Largest first.
        return bytesCurrentB.compareTo(bytesCurrentA);
      });
    }
    return collectedData;
  } finally {
    await serviceClient.dispose();
  }
}

void main(List<String> arguments) async {
  print('Finding Dart LSP processes');
  final lspProcesses = await getDartLspProcesses();
  if (lspProcesses.isEmpty) {
    print('No LSP processes found');
    exit(0);
  }
  printProcesses(lspProcesses);

  late Map<int, Uri> uris;
  late Set<int> lspProcessesWithoutVmServiceUri;
  for (var attempt = 0; attempt < 3; attempt++) {
    print('Trying to fetch vm-service URIs');
    uris = await getVmServiceUris(lspProcesses);
    printProcesses(uris);

    lspProcessesWithoutVmServiceUri =
        Set.of(lspProcesses.keys).difference(Set.of(uris.keys));
    if (lspProcessesWithoutVmServiceUri.isEmpty) {
      break;
    }
    print(
        '-> LSP processes without service URI: $lspProcessesWithoutVmServiceUri');
    for (var lspWithoutDDS in lspProcessesWithoutVmServiceUri) {
      print(
          ' | Sending SIGQUIT to $lspWithoutDDS in attempt to start vm-service');
      print(' | WARNING: this will damage connection between VS Code and LSP server and you will later need to restart analyzer');
      try {
        execute('kill', ['-QUIT', '$lspWithoutDDS']);
        print(' | - OK');
      } catch (_) {
        print(' | - FAILED');
      }
    }
    print('Waiting 5s for DDS to start.');
    await Future.delayed(const Duration(seconds: 5));
  }

  final data = <String, dynamic>{};
  for (var entry in uris.entries) {
    print(
        'Trying to fetch data from LSP process ${entry.key} via ${entry.value}');
    try {
      data[entry.key.toString()] = await collectDataFrom(entry.value);
      print('... OK');
    } catch (_) {
      print('... FAILED');
    }
  }
  File('lsp-report.json')
      .writeAsStringSync(JsonEncoder.withIndent('  ').convert(data));
  print('SUCCESS: written lsp-report.json');
}
