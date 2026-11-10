// Parsing and version logic for requirements.txt and the shared
// site-packages store. Pure Dart — no platform calls, fully unit tested.
//
// The store itself is already shared: pip installs into the app's single
// `<HOME>/site-packages`, reused by every project. This file makes that
// visible and robust: parse requirements, compare installed versions,
// and decide what (if anything) still needs installing.

/// One line of a requirements.txt (after stripping markers/comments).
class Requirement {
  /// Normalized name (lower-case, `_` -> `-`), used as the map key.
  final String name;

  /// Name as written in the file.
  final String displayName;
  final List<VersionConstraint> constraints;
  final String raw;

  const Requirement({
    required this.name,
    required this.displayName,
    required this.constraints,
    required this.raw,
  });

  bool get hasSpecifier => constraints.isNotEmpty;

  /// True when [installedVersion] (null = not installed) satisfies this
  /// requirement.
  bool satisfiedBy(String? installedVersion) {
    if (installedVersion == null) return false;
    return constraints.every((c) => c.holds(installedVersion));
  }
}

class VersionConstraint {
  final String op; // ==, >=, <=, >, <, !=, ~=
  final String version;

  const VersionConstraint(this.op, this.version);

  bool holds(String installed) {
    final cmp = compareVersions(installed, version);
    switch (op) {
      case '==':
        return cmp == 0;
      case '>=':
        return cmp >= 0;
      case '<=':
        return cmp <= 0;
      case '>':
        return cmp > 0;
      case '<':
        return cmp < 0;
      case '!=':
        return cmp != 0;
      case '~=':
        // Compatible release: >= version and the same prefix as version
        // without its last segment (e.g. ~=2.3 -> >=2.3, <3.0).
        if (cmp < 0) return false;
        final parts = version.split('.');
        if (parts.length <= 1) return true;
        final prefix = parts.sublist(0, parts.length - 1);
        final installedParts = installed.split('.');
        for (var i = 0; i < prefix.length; i++) {
          if (i >= installedParts.length) return false;
          if (compareVersions(installedParts[i], prefix[i]) != 0) {
            return false;
          }
        }
        return true;
      default:
        return true;
    }
  }
}

/// Parse one requirements.txt line. Returns null for blank lines,
/// comments, options (-r, --index-url, ...) and unparseable lines.
Requirement? parseRequirement(String line) {
  var text = line.trim();
  if (text.isEmpty || text.startsWith('#')) return null;
  if (text.startsWith('-')) return null; // -r, --index-url, ...
  // Environment markers and inline comments.
  final marker = text.indexOf(';');
  if (marker >= 0) text = text.substring(0, marker).trim();
  final comment = text.indexOf(' #');
  if (comment >= 0) text = text.substring(0, comment).trim();
  if (text.isEmpty) return null;
  // Name, optional [extras], then the specifier string.
  final m = RegExp(r'^([A-Za-z0-9_.\-]+)(\[[^\]]*\])?\s*(.*)$')
      .firstMatch(text);
  if (m == null) return null;
  final name = m.group(1)!;
  final specText = (m.group(3) ?? '').trim();
  final constraints = <VersionConstraint>[];
  if (specText.isNotEmpty) {
    for (final part in specText.split(',')) {
      final c = RegExp(r'^(==|>=|<=|!=|~=|>|<|===)\s*([^\s,;]+)$')
          .firstMatch(part.trim());
      if (c == null) return null;
      final op = c.group(1) == '===' ? '==' : c.group(1)!;
      constraints.add(VersionConstraint(op, c.group(2)!));
    }
  }
  return Requirement(
    name: name.toLowerCase().replaceAll('_', '-'),
    displayName: name,
    constraints: constraints,
    raw: line.trim(),
  );
}

/// Parse all requirements from a requirements.txt file's text.
List<Requirement> parseRequirementsText(String content) {
  final out = <Requirement>[];
  for (final line in content.split('\n')) {
    final req = parseRequirement(line);
    if (req != null) out.add(req);
  }
  return out;
}

/// Compare two version strings (numeric segments, pre-release suffixes
/// sort before the release: 1.0rc1 < 1.0). Returns negative / 0 / positive.
int compareVersions(String a, String b) {
  final aParts = a.trim().split('.');
  final bParts = b.trim().split('.');
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final ap = i < aParts.length ? aParts[i] : '0';
    final bp = i < bParts.length ? bParts[i] : '0';
    final aNum = _numPrefix(ap);
    final bNum = _numPrefix(bp);
    if (aNum != bNum) return aNum.compareTo(bNum);
    final aRest = ap.substring(aNum.toString().length);
    final bRest = bp.substring(bNum.toString().length);
    if (aRest != bRest) {
      // A bare release sorts after its pre-releases: 1.0 > 1.0rc1.
      if (aRest.isEmpty) return 1;
      if (bRest.isEmpty) return -1;
      return aRest.compareTo(bRest);
    }
  }
  return 0;
}

int _numPrefix(String segment) {
  final m = RegExp(r'^\d+').firstMatch(segment);
  return m == null ? 0 : int.parse(m.group(0)!);
}

/// Parse `pip list` / installed_packages() output ("name==version" lines)
/// into a map keyed by normalized (lower-case) name.
Map<String, String> parseInstalledPackages(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final idx = t.lastIndexOf('==');
    if (idx <= 0) continue;
    out[t
            .substring(0, idx)
            .trim()
            .toLowerCase()
            .replaceAll('_', '-')] = t.substring(idx + 2).trim();
  }
  return out;
}

enum RequirementStatus { satisfied, missing, mismatch }

RequirementStatus requirementStatus(
  Requirement req,
  Map<String, String> installed,
) {
  final version = installed[req.name];
  if (version == null) return RequirementStatus.missing;
  return req.satisfiedBy(version)
      ? RequirementStatus.satisfied
      : RequirementStatus.mismatch;
}

/// The pip argument that installs [req] as specified
/// (e.g. `requests==2.31.0`, `flask>=2.0`, or just `click`).
String pipArgFor(Requirement req) {
  if (req.constraints.isEmpty) return req.displayName;
  final spec =
      req.constraints.map((c) => '${c.op}${c.version}').join(',');
  return '${req.displayName}$spec';
}
