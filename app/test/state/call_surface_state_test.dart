// The call surface is the one thing about a call that is global: which shape
// of it is on screen. Everything that changes every few tens of milliseconds
// (the level, the caption) stays with the stage that draws it.

import 'package:dsh_app/state/call_surface_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no call is shown until something says so', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(callSurfaceProvider), CallSurface.none);
  });

  test('the surface follows whoever is showing the call', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final seen = <CallSurface>[];
    container.listen(callSurfaceProvider, (_, next) => seen.add(next));

    container.read(callSurfaceProvider.notifier).set(CallSurface.full);
    expect(container.read(callSurfaceProvider), CallSurface.full);

    // Shrinking is a change too; the same shape twice is not.
    container.read(callSurfaceProvider.notifier).set(CallSurface.expanded);
    container.read(callSurfaceProvider.notifier).set(CallSurface.expanded);
    container.read(callSurfaceProvider.notifier).set(CallSurface.none);

    expect(seen, [CallSurface.full, CallSurface.expanded, CallSurface.none]);
  });
}
