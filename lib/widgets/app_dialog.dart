import 'package:flutter/material.dart';

/// Shared, modern dialog styles used across the app (create file/folder,
/// rename, delete confirmations). Rounded, icon-led, and theme-aware
/// (dark/light comes from the ambient Theme).

/// Validate a file/folder/project name. Returns an error message, or null
/// when the name is fine. [existingNames] are lower-case names that would
/// collide (duplicates are rejected).
String? validateFileName(String name, Set<String> existingNames) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Enter a name.';
  if (trimmed == '.' || trimmed == '..') {
    return 'That name is not allowed.';
  }
  const illegal = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
  for (final c in illegal) {
    if (trimmed.contains(c)) return 'Names cannot contain "$c".';
  }
  if (trimmed.codeUnits.any((c) => c < 32)) {
    return 'Names cannot contain control characters.';
  }
  if (existingNames.contains(trimmed.toLowerCase())) {
    return 'A file or folder with this name already exists.';
  }
  return null;
}

/// Rounded name-input dialog with an icon header and live validation.
/// Returns the trimmed name, or null when cancelled.
Future<String?> showNameInputDialog({
  required BuildContext context,
  required String title,
  required IconData icon,
  required String hint,
  String initialValue = '',
  String confirmLabel = 'Create',
  Set<String> existingNames = const {},
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NameInputDialog(
      title: title,
      icon: icon,
      hint: hint,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      existingNames: existingNames,
    ),
  );
}

class _NameInputDialog extends StatefulWidget {
  final String title;
  final IconData icon;
  final String hint;
  final String initialValue;
  final String confirmLabel;
  final Set<String> existingNames;

  const _NameInputDialog({
    required this.title,
    required this.icon,
    required this.hint,
    required this.initialValue,
    required this.confirmLabel,
    required this.existingNames,
  });

  @override
  State<_NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<_NameInputDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _error = validateFileName(_controller.text, widget.existingNames);
    _controller.addListener(() {
      final error =
          validateFileName(_controller.text, widget.existingNames);
      if (error != _error) setState(() => _error = error);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_error != null) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final valid = _error == null && _controller.text.trim().isNotEmpty;
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.icon,
                    color: cs.onPrimaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: widget.hint,
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: valid ? _submit : null,
                  child: Text(widget.confirmLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded confirmation dialog with an icon header. Returns true when the
/// confirm action was tapped, false / null otherwise.
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required IconData icon,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: destructive
                          ? cs.errorContainer
                          : cs.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      color: destructive
                          ? cs.onErrorContainer
                          : cs.onPrimaryContainer,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(message),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: destructive
                        ? FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          )
                        : null,
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
