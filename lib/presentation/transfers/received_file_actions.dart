import 'package:flutter/widgets.dart' show Rect;

/// Injectable seam for the OS-handoff actions on a received file, so the
/// transfer tile never imports open_filex / share_plus / dart:io directly.
/// Constructed at the composition root (receivedFileActionsProvider) and
/// recorder-overridable in widget tests.
typedef OpenSavedFileFn = Future<void> Function(String savedPath);
typedef RevealSavedFileFn = Future<void> Function(String savedPath);
typedef ShareSavedFileFn = Future<void> Function(String savedPath,
    {Rect? origin});

class ReceivedFileActions {
  const ReceivedFileActions({
    required this.open,
    required this.reveal,
    required this.shareOnward,
  });

  /// Open the file in the OS default handler (routes content:// URIs).
  final OpenSavedFileFn open;

  /// Reveal the file in the OS file manager (desktop); degrades to [open].
  final RevealSavedFileFn reveal;

  /// Re-share the file via the OS share sheet. [origin] positions the iPad
  /// share popover.
  final ShareSavedFileFn shareOnward;
}
