import 'dart:js_interop';

@JS('FlowTraceShell')
external JSObject? get _flowTraceShell;

extension type _Shell._(JSObject _) implements JSObject {
  external JSFunction registerUpdateBarrier(_Barrier barrier);
}

extension type _Barrier._(JSObject _) implements JSObject {
  external factory _Barrier({JSFunction prepare, JSFunction resume});
}

void Function() registerShellUpdateBarrier({
  required Future<bool> Function() prepare,
  required void Function() resume,
}) {
  final shell = _flowTraceShell;
  if (shell == null) return () {};
  final barrier = _Barrier(
    prepare: (() => prepare().then((value) => value.toJS).toJS).toJS,
    resume: resume.toJS,
  );
  final unregister = _Shell._(shell).registerUpdateBarrier(barrier);
  return () {
    unregister.callAsFunction();
  };
}
