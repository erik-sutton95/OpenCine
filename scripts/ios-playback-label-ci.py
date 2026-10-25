#!/usr/bin/env python3
"""Portable CI enrollment of the unchanged SIMULATED native playback cancellation contract.

Source generation is read-only. Native execution uses a caller-owned private CI simulator;
the local qualification runner and its retained review packets remain separate.
"""
import argparse
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import time
from uuid import UUID, uuid4

TEMPLATES = ('NativeCancelReceipt.swift', 'SimulatedNativeCancelHost.swift', 'NativeCancelUITests.swift')
PARENT_PREDICATES = frozenset({'childNativeQualified', 'sourceUnchanged', 'sourceFactsUnchanged',
                               'generatedUnchanged', 'sharedSeedUnchanged', 'ownedReadersExited',
                               'deviceShutdownObserved', 'privateAppDataRetained', 'parentWallHeld'})

def load_legacy(root):
    source = root / 'scripts/ios-playback-label-hosted-test.py'
    spec = importlib.util.spec_from_file_location('playback_native_contract', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def source_binding(root):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], timeout=30)
    inputs = {'Package.swift', 'Fixtures/playback-copy.tsv',
              'scripts/ios-playback-label-hosted-test.py',
              'Tests/MonitorUIHostedTests/MonitorPlaybackAccessibilityLabelTests.swift'}
    inputs.update('scripts/ios-playback-label-native-system-dismissal/' + name for name in TEMPLATES)
    inputs.update(name for name in git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0') if name)
    return {'head': git('rev-parse', 'HEAD').decode().strip(),
            'tree': git('rev-parse', 'HEAD^{tree}').decode().strip(),
            'workingDiffSHA256': sha256(git('diff', 'HEAD', '--binary')).hexdigest(),
            'inputSHA256': {name: sha256((root / name).read_bytes()).hexdigest()
                            for name in sorted(inputs) if (root / name).is_file()}}

def project_spec(root, out, nonce, seal):
    legacy = load_legacy(root)
    host = 'OpenCinePlaybackNativeSystemDismissalSimulated'
    bundle = 'com.opencapture.opencine.simulated.playbacklabels.systemdismiss.run' + nonce.replace('-', '')
    common = str(out / 'NativeCancelReceipt.swift')
    return {
        'name': legacy.SYSTEM_SCHEME,
        'options': {'deploymentTarget': {'iOS': '17.0'}},
        'settings': {'base': {'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES',
                              'TARGETED_DEVICE_FAMILY': '1,2', 'SUPPORTED_PLATFORMS': 'iphonesimulator'}},
        'packages': {'OpenCine': {'path': str(root)}},
        'targets': {
            host: {'type': 'application', 'platform': 'iOS',
                   'sources': [common, str(out / 'SimulatedNativeCancelHost.swift')],
                   'dependencies': [{'package': 'OpenCine', 'product': name}
                                    for name in ['MonitorPresentation', 'MonitorUI', 'OpenCineMedia']],
                   'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': bundle,
                                        'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
                                        'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
            legacy.SYSTEM_TARGET: {'type': 'bundle.ui-testing', 'platform': 'iOS',
                                   'sources': [common, str(out / 'NativeCancelUITests.swift')],
                                   'dependencies': [{'target': host}] + [{'package': 'OpenCine', 'product': name}
                                       for name in ['MonitorPresentation', 'OpenCineHostedTestSupport']],
                                   'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': bundle + '.uitests',
                                                        'TEST_TARGET_NAME': host}}},
        },
        'schemes': {legacy.SYSTEM_SCHEME: {
            'build': {'targets': {host: ['test'], legacy.SYSTEM_TARGET: ['test']}},
            # No automatic screen recording or per-event screenshots: on the GPU-less hosted runner the
            # recorder competes with the driver's one explicit evidence screenshot (40143225461: the
            # recording never finalized and that screenshot timed out after 168 s).
            'test': {'config': 'Debug', 'macroExpansion': host,
                     'captureScreenshotsAutomatically': False, 'preferredScreenCaptureFormat': 'screenshots',
                     'targets': [{'name': legacy.SYSTEM_TARGET, 'parallelizable': False, 'randomExecutionOrder': False}],
                     'environmentVariables': {'OPENCINE_NATIVE_UI_NONCE': nonce,
                                              'OPENCINE_NATIVE_UI_SOURCE_SEAL': seal,
                                              'OPENCINE_NATIVE_UI_BUNDLE_ID': bundle,
                                              'OPENCINE_NATIVE_UI_MODE': legacy.SYSTEM_MODE}}}},
    }

def native_command(legacy, out, simulator_id):
    """The sole xcodebuild invocation for the one native method on the caller-owned simulator."""
    return ['xcodebuild', '-project', str(out / (legacy.SYSTEM_SCHEME + '.xcodeproj')),
            '-scheme', legacy.SYSTEM_SCHEME, '-destination', 'platform=iOS Simulator,id=' + simulator_id,
            '-derivedDataPath', str(out / 'DerivedData'), '-clonedSourcePackagesDirPath', str(out / 'SourcePackages'),
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            # The whole-case allowance covers launch, AX queries and teardown evidence outside the
            # original thirty-second readiness and settlement deadlines, which stay in the driver.
            # Hosted launches alone took 13 to 38 s; native2400 and progress180 still bound hangs.
            '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '360',
            '-maximum-test-execution-time-allowance', '360', '-resultBundlePath', str(out / 'result.xcresult'),
            'CODE_SIGNING_ALLOWED=NO', '-only-testing:' + legacy.SYSTEM_TARGET + '/NativeCancelUITests/'
            + legacy.NATIVE_UI_METHOD, 'test']

def native_result(legacy, child_exit, text, prepared, records, bridge_error, integrity, watchdog=None):
    """Evaluate actual raw app bytes and the exact sole native method, with no success defaults."""
    all_native = re.findall(r"Test Case '([^\n]+)\' (passed|failed|skipped)", text)
    exact = [('-[' + legacy.SYSTEM_TARGET + '.NativeCancelUITests ' + legacy.NATIVE_UI_METHOD + ']', 'passed')]
    values = [json.loads(value) for value in re.findall(r'SIMULATED_NATIVE_UI_OUTCOME:({[^\r\n]+})', text)]
    driver = values[0] if len(values) == 1 else {}
    def actual(sequence, digest):
        matching = [row for row in records if row['sequence'] == sequence and row['sha256'] == digest]
        if len(matching) != 1:
            return {}
        data = Path(matching[0]['retained']).read_bytes()
        if sha256(data).hexdigest() != digest:
            return {}
        return json.loads(data)
    app = actual(driver.get('sequence'), driver.get('appReceiptSHA256'))
    pre = actual(driver.get('preInputAppSequence'), driver.get('preInputAppSHA256'))
    try:
        settled = bool(app) and app['cancelled'] == [app['requestID']] and not app['confirmed'] \
            and app['captureRequestIDs'] == [app['requestID']] and app['capturedItems'] == [app['item']] \
            and app['deletedCount'] == 0 and not app['activeRequestIDs'] \
            and app['retiredRequestIDs'] == [app['requestID']] and app['dialogWindowGone'] is True \
            and app['presentingControllerGone'] is True and app.get('popup') is None
    except (KeyError, TypeError):
        settled = False
    window_failures = legacy.system_window_failures(pre)
    checks = {
        'soleNativeCasePassed': all_native == exact, 'singleDriverOutcome': len(values) == 1,
        'driverNonceBound': driver.get('nonce') == prepared['nonce'],
        'driverSourceBound': driver.get('sourceSeal') == prepared['sourceSeal'],
        'driverBundleBound': driver.get('bundleID') == prepared['bundleID'],
        'driverSimulatorBound': driver.get('simulatorID', '').upper() == prepared['simulatorID'].upper(),
        'explicitSystemMode': driver.get('outsideInputImplemented') is True and driver.get('mode') == legacy.SYSTEM_MODE,
        'driverQualified': driver.get('qualified') is True, 'openingDeleteInvoked': driver.get('deleteTapInvoked') is True,
        'systemDismissalInvoked': driver.get('systemDismissalTapInvoked') is True,
        'noCancelInvocation': driver.get('cancelTapInvoked') is False,
        'actualAppSettlement': bool(settled), 'bridgeHealthy': bridge_error is None,
        'preInputReceiptBound': bool(pre), 'otherWindowInterceptionExcluded': not window_failures,
        'originalReadinessDeadlineHeld': legacy.system_deadline_held(driver.get('eventReadinessElapsedSeconds')),
        **integrity,
    }
    errors = window_failures + (['watchdog:' + watchdog] if watchdog else [])
    verdict = legacy.system_final_verdict(child_exit, checks, errors)
    return {**verdict, 'successPredicates': checks, 'driver': driver,
            'appReceiptSHA256': driver.get('appReceiptSHA256') if app else None}

def run_native(command, bridge, out, deadline):
    """One owned reader; original native2400/progress180 inside the parent3600 bound."""
    if time.monotonic() >= deadline:
        raise TimeoutError('Parent deadline expired before reader admission')
    log_path = out / 'xcodebuild.log'
    started = last = time.monotonic()
    size = 0
    watchdog = bridge_error = None
    with log_path.open('wb') as log:
        (out / 'owned-reader.json').write_text(json.dumps({'state': 'starting', 'command': command}) + '\n')
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        owner = {'pid': process.pid, 'pgid': process.pid, 'command': command, 'state': 'running',
                 'newSession': True, 'groupObserved': False, 'groupExited': False,
                 'groupObservations': [], 'signals': []}
        try:
            owner['groupObserved'] = os.getpgid(process.pid) == process.pid == os.getsid(process.pid)
            (out / 'owned-reader.json').write_text(json.dumps(owner, indent=2) + '\n')
            if not owner['groupObserved']:
                raise RuntimeError('The reader did not enter its admitted private session')
            while process.poll() is None:
                time.sleep(0.1)
                now = time.monotonic()
                current = log_path.stat().st_size
                if current != size:
                    size, last = current, now
                if bridge is not None and bridge_error is None:
                    try:
                        bridge.observe(log_path.read_text(errors='replace'))
                    except Exception as error:
                        bridge_error = repr(error)
                if now >= deadline or now - started > 2400 or now - last > 180:
                    watchdog = 'parent3600' if now >= deadline else ('native2400' if now - started > 2400 else 'no-progress180')
                    break
            now = time.monotonic()
            if watchdog is None and (now >= deadline or now - started > 2400 or now - last > 180):
                watchdog = 'parent3600' if now >= deadline else ('native2400' if now - started > 2400 else 'no-progress180')
        finally:
            cleanup_deadline = time.monotonic() + 40
            try:
                if not owner['groupObserved']:
                    raise RuntimeError('Owned session identity was not observed')
                for stop in (signal.SIGINT, signal.SIGKILL):
                    if observe_group_exit(owner, cleanup_deadline):
                        owner['groupExited'] = process.poll() is not None
                        break
                    if process.poll() is not None:
                        watchdog = watchdog or 'ownedReaderGroupOutlivedLeader'
                    # Every selected member was just observed in this Popen's private session.
                    # Never signal after the group has been observed absent.
                    members = owner['groupObservations'][-1]['members']
                    if members and all(row['sessionObserved'] for row in members):
                        try:
                            os.killpg(process.pid, stop)
                            owner['signals'].append(int(stop))
                        except ProcessLookupError:
                            pass
                    end = min(cleanup_deadline, time.monotonic() + 20)
                    while time.monotonic() < end:
                        code = process.poll()
                        if observe_group_exit(owner, end) and code is not None:
                            owner['groupExited'] = True
                            break
                        time.sleep(min(0.1, max(0, end - time.monotonic())))
                    if owner['groupExited']:
                        break
                if not owner['groupExited']:
                    watchdog = watchdog or 'ownedReaderGroupExitUnproved'
            except Exception as error:
                owner['groupExitError'] = repr(error)
                watchdog = watchdog or 'ownedReaderGroupExitUnknown'
            code = process.poll()
            owner.update(state='exited' if owner['groupExited'] and code is not None else 'readersUnknown', exit=code)
            (out / 'owned-reader.json').write_text(json.dumps(owner, indent=2) + '\n')
    return code if code is not None else 1, watchdog, bridge_error

def group_members(pgid, timeout=5):
    if type(pgid) is not int or pgid <= 1:
        raise RuntimeError('Invalid owned process group')
    result = subprocess.run(['ps', '-o', 'pid=,ppid=,pgid=,stat=,lstart=', '-g', str(pgid)],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode not in (0, 1) or result.stderr or (result.returncode == 1 and result.stdout.strip()):
        raise RuntimeError('Owned process-group observation failed')
    members = []
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=4)
        if len(fields) != 5 or int(fields[2]) != pgid or not fields[3] or not fields[4]:
            raise RuntimeError('Incomplete process-group identity observation')
        pid = int(fields[0])
        session_observed = False
        try:
            if os.getsid(pid) != pgid:
                raise RuntimeError('Process no longer belongs to the admitted private session')
            session_observed = True
        except ProcessLookupError:
            continue
        except PermissionError:
            # A process can leave the readable session table after ps captured its row.
            # Retain it as unproved and wait; it cannot authorize a group signal or cleanup.
            pass
        members.append({'pid': pid, 'parent': int(fields[1]), 'pgid': int(fields[2]),
                        'state': fields[3], 'started': fields[4], 'sessionObserved': session_observed})
    return members

def observe_group_exit(owner, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('Owned reader group observation budget expired')
    members = group_members(owner['pgid'], timeout=min(5, remaining))
    absent = False
    if not members:
        try:
            os.killpg(owner['pgid'], 0)
        except ProcessLookupError:
            absent = True
        except PermissionError:
            pass
    owner['groupObservations'].append({'monotonic': time.monotonic(), 'members': members, 'groupAbsent': absent})
    return absent

def reader_exit_proven(out):
    try:
        owner = json.loads((out / 'owned-reader.json').read_text())
        observations = owner.get('groupObservations', [])
        return owner['state'] == 'exited' and type(owner.get('exit')) is int \
            and type(owner.get('pid')) is int and owner['pid'] > 1 and owner['pgid'] == owner['pid'] \
            and owner.get('newSession') is True and owner.get('groupObserved') is True \
            and owner.get('groupExited') is True and bool(observations) \
            and observations[-1].get('groupAbsent') is True and observations[-1].get('members') == [] \
            and observe_group_exit(owner, time.monotonic() + 5)
    except Exception:
        return False

def shutdown_private_device(out, simulator, expected_name):
    if not reader_exit_proven(out):
        raise RuntimeError('No shutdown or copy: owned reader-group exit is unproved')
    UUID(simulator)
    device = Path.home() / 'Library/Developer/CoreSimulator/Devices' / simulator / 'device.plist'
    metadata = plistlib.loads(device.read_bytes())
    if metadata['name'] != expected_name or metadata['deviceType'] != 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro':
        raise RuntimeError('Caller-owned device identity changed')
    def current():
        listed = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], timeout=30))
        return [value for group in listed['devices'].values() for value in group
                if value['udid'] == simulator and value['name'] == expected_name]
    matches = current()
    if len(matches) != 1:
        raise RuntimeError('Private device observation is incomplete')
    if matches[0]['state'] != 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'shutdown', simulator], capture_output=True, timeout=30)
    matches = current()
    return len(matches) == 1 and matches[0]['state'] == 'Shutdown'

def retain_private_app_data(out, containers, bundle_ids):
    if not reader_exit_proven(out):
        raise RuntimeError('No shutdown or copy: owned reader-group exit is unproved')
    copied = []
    for container in containers.iterdir():
        metadata = container / '.com.apple.mobile_container_manager.metadata.plist'
        if metadata.is_file() and plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier') in bundle_ids:
            shutil.copytree(container, out / 'private-app-data' / container.name)
            copied.append(container.name)
    return len(copied) == 2

def dependency_binding(root):
    # This developer project uses the dependency-free OpenCine root package. A future external
    # dependency needs an explicit resolved-input contract before it can use this entry.
    manifest = (root / 'Package.swift').read_bytes()
    if re.search(rb'\.package\s*\(', manifest):
        raise RuntimeError('External package inputs require an explicit portable resolved-input binding')
    resolved = root / 'Package.resolved'
    return {'localManifestSHA256': sha256(manifest).hexdigest(),
            'resolvedSHA256': sha256(resolved.read_bytes()).hexdigest() if resolved.is_file() else None,
            'externalPackageDeclarations': 0}

def prepare(root, out):
    if out.exists() or out.is_relative_to(root):
        raise RuntimeError('Use a fresh output outside the source checkout; retain earlier results')
    out.mkdir(parents=True)
    binding = source_binding(root)
    nonce = str(uuid4())
    seal = sha256(json.dumps(binding, sort_keys=True).encode()).hexdigest()
    for name in TEMPLATES:
        shutil.copy2(root / 'scripts/ios-playback-label-native-system-dismissal' / name, out / name)
    spec = project_spec(root, out, nonce, seal)
    (out / 'project.json').write_text(json.dumps(spec, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(out / 'project.json'), '--project', str(out)], check=True, timeout=60)
    legacy = load_legacy(root)
    project = out / (legacy.SYSTEM_SCHEME + '.xcodeproj')
    generated = {str(path.relative_to(out)): sha256(path.read_bytes()).hexdigest() for path in
                 [out / name for name in TEMPLATES] + [out / 'project.json', project / 'project.pbxproj',
                  project / 'xcshareddata/xcschemes' / (legacy.SYSTEM_SCHEME + '.xcscheme')]}
    host = 'OpenCinePlaybackNativeSystemDismissalSimulated'
    bundle = spec['targets'][host]['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER']
    packet = {'nonce': nonce, 'sourceSeal': seal, 'sourceBinding': binding, 'generated': generated,
              'bundleID': bundle, 'runnerBundleID': bundle + '.uitests.xctrunner',
              'dependencyBinding': dependency_binding(root), 'originalReadinessSeconds': 30,
              'originalSettlementSeconds': 30, 'nativeWallSeconds': 2400,
              'progressSeconds': 180, 'parentWallSeconds': 3600,
              'legacyThreeCaseGate': 'Retained separately in kit-ios; this case cannot waive its failures',
              'scope': 'SIMULATED portable CI source plan; no native result is inferred'}
    (out / 'prepared.json').write_text(json.dumps(packet, indent=2) + '\n')
    if source_binding(root) != binding:
        raise RuntimeError('Source changed while preparing the project')
    return packet

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true', help='Execute only on an explicitly owned GitHub CI simulator')
    parser.add_argument('--cleanup', action='store_true', help='Shutdown only after positive owned reader-group exit proof')
    parser.add_argument('--simulator-id')
    parser.add_argument('--expected-device-name')
    args = parser.parse_args()
    started = time.monotonic()
    def parent_expired(_signal, _frame):
        raise TimeoutError('Whole portable parent3600 expired; retain partial outputs without a success claim')
    signal.signal(signal.SIGALRM, parent_expired)
    signal.setitimer(signal.ITIMER_REAL, 3595)
    root, out = args.source_root.resolve(), args.output.resolve()
    if args.cleanup:
        if args.run or os.environ.get('GITHUB_ACTIONS') != 'true' or not args.simulator_id or not args.expected_device_name:
            raise RuntimeError('CI cleanup needs exact caller-owned device identity')
        shutdown = shutdown_private_device(out, args.simulator_id, args.expected_device_name)
        print(json.dumps({'ownedReadersExited': reader_exit_proven(out), 'shutdownObserved': shutdown}))
        return 0 if shutdown else 1
    packet = prepare(root, out)
    if not args.run:
        print(json.dumps({'prepared': str(out), 'nativeExecution': False, 'sourceSeal': packet['sourceSeal']}))
        return 0
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('This portable execution entry is CI-only; local qualification uses its reviewed lifecycle runner')
    if not args.simulator_id or not args.expected_device_name:
        raise RuntimeError('An exact caller-owned simulator ID and name are required')
    UUID(args.simulator_id)
    device_root = Path.home() / 'Library/Developer/CoreSimulator/Devices' / args.simulator_id
    device = plistlib.loads((device_root / 'device.plist').read_bytes())
    if device['name'] != args.expected_device_name or device['deviceType'] != 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro':
        raise RuntimeError('Private device identity does not match the caller contract')
    floors = {}
    for path in [out, device_root, Path(os.environ.get('TMPDIR', '/tmp')),
                 Path.home() / 'Library/Caches/org.swift.swiftpm']:
        actual = path
        while not actual.exists():
            actual = actual.parent
        value = os.statvfs(actual)
        floors[str(path)] = {'resolved': str(path.resolve()), 'freeBytes': value.f_bavail * value.f_frsize}
        if floors[str(path)]['freeBytes'] < 20 * 2**30:
            raise RuntimeError('Actual native userdata/cache/temp/output below20GiB: ' + str(path))
    legacy = load_legacy(root)
    packet['simulatorID'] = args.simulator_id
    bridge = legacy.NativeUIReceiptBridge(args.simulator_id, packet, out)
    command = native_command(legacy, out, args.simulator_id)
    (out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    code, watchdog, error = run_native(command, bridge, out, started + 3540)
    after = source_binding(root)
    integrity = {'sourceUnchanged': after == packet['sourceBinding'],
                 'sourceFactsUnchanged': all(after[key] == packet['sourceBinding'][key] for key in ['head', 'tree']),
                 'generatedUnchanged': all(sha256((out / name).read_bytes()).hexdigest() == digest
                                           for name, digest in packet['generated'].items()),
                 'sharedSeedUnchanged': dependency_binding(root) == packet['dependencyBinding']}
    native = native_result(legacy, code, (out / 'xcodebuild.log').read_text(errors='replace'),
                           packet, bridge.records, error, integrity, watchdog=watchdog)
    (out / 'native-receipt.json').write_text(json.dumps(dict(native, bridgeRecords=bridge.records,
                                               bridgeError=error, watchdog=watchdog, admission=floors), indent=2) + '\n')
    # No device action or archive is allowed while the sole native reader might still exist.
    exited = reader_exit_proven(out)
    shutdown = retained = False
    retention_error = None
    if exited:
        try:
            shutdown = shutdown_private_device(out, args.simulator_id, args.expected_device_name)
            if shutdown:
                retained = retain_private_app_data(out, device_root / 'data/Containers/Data/Application',
                                                   [packet['bundleID'], packet['runnerBundleID']])
        except Exception as caught:
            retention_error = repr(caught)
    checks = {'childNativeQualified': native['qualified'], **integrity, 'ownedReadersExited': exited,
              'deviceShutdownObserved': shutdown, 'privateAppDataRetained': retained,
              'parentWallHeld': time.monotonic() - started < 3600}
    verdict = legacy.system_final_verdict(native['exit'], checks,
                                          [retention_error] if retention_error else [], required=PARENT_PREDICATES)
    (out / 'receipt.json').write_text(json.dumps(dict(verdict, lifecyclePredicates=checks,
                                        nativeReceipt='native-receipt.json', physical='untested'), indent=2) + '\n')
    print(json.dumps(verdict), flush=True)
    return verdict['exit']

if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
