import 'package:flutter/widgets.dart';

/// Reports its child's rendered size via [onChange] after each layout. Used to
/// resize the frameless popover window to fit its content.
class MeasureSize extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onChange;

  const MeasureSize({super.key, required this.child, required this.onChange});

  @override
  State<MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<MeasureSize> {
  final _key = GlobalKey();
  Size? _last;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = _key.currentContext?.size;
      if (size != null && size != _last) {
        _last = size;
        widget.onChange(size);
      }
    });
    return Align(
      alignment: Alignment.topCenter,
      child: KeyedSubtree(key: _key, child: widget.child),
    );
  }
}
