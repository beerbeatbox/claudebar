import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports its child's *natural* height via [onChange] after each layout, used
/// to resize the frameless popover window to fit its content.
///
/// Implemented as a render object (not a postframe callback in `build`) so it
/// fires on **every** layout — including when only the child rebuilds, e.g. the
/// usage data arriving via Riverpod. The child is measured with an unbounded
/// height so the reported size never gets clamped to the current (smaller)
/// window, which would otherwise leave the popover stuck clipped.
class MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;

  const MeasureSize({super.key, required this.onChange, required Widget child})
    : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRender(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _MeasureSizeRender).onChange = onChange;
  }
}

class _MeasureSizeRender extends RenderProxyBox {
  _MeasureSizeRender(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Measure the child at its natural height (width still bound to the window),
    // then size self clamped to the incoming constraints.
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
      ),
      parentUsesSize: true,
    );
    final natural = child.size;
    size = constraints.constrain(natural);

    if (_last != natural) {
      _last = natural;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(natural));
    }
  }
}
