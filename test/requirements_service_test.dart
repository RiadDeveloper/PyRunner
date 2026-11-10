// Unit tests for lib/services/requirements_service.dart — parsing,
// version comparison, specifier satisfaction, and install decisions.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/requirements_service.dart';

void main() {
  group('compareVersions', () {
    test('numeric segments compare numerically', () {
      expect(compareVersions('2.9.0', '2.10.0'), lessThan(0));
      expect(compareVersions('2.10.0', '2.9.0'), greaterThan(0));
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('pre-releases sort before the release', () {
      expect(compareVersions('1.0rc1', '1.0'), lessThan(0));
      expect(compareVersions('1.0a1', '1.0b1'), lessThan(0));
    });
  });

  group('parseRequirement', () {
    test('bare name', () {
      final r = parseRequirement('requests')!;
      expect(r.name, 'requests');
      expect(r.hasSpecifier, isFalse);
      expect(r.satisfiedBy('2.31.0'), isTrue);
      expect(r.satisfiedBy(null), isFalse);
    });

    test('==, >= and ~= specifiers', () {
      expect(parseRequirement('numpy==1.26.4')!.constraints.first.op, '==');
      final gte = parseRequirement('flask>=2.0')!;
      expect(gte.satisfiedBy('2.3.1'), isTrue);
      expect(gte.satisfiedBy('1.9.9'), isFalse);
      final compat = parseRequirement('Django~=4.2')!;
      expect(compat.satisfiedBy('4.2.9'), isTrue);
      expect(compat.satisfiedBy('5.0'), isFalse);
      expect(compat.satisfiedBy('4.1.9'), isFalse);
    });

    test('comma-separated ranges', () {
      final r = parseRequirement('requests>=2.0,<3.0')!;
      expect(r.satisfiedBy('2.31.0'), isTrue);
      expect(r.satisfiedBy('3.0.0'), isFalse);
      expect(r.satisfiedBy('1.9.0'), isFalse);
    });

    test('comments, markers, extras and options are handled', () {
      expect(parseRequirement('# just a comment'), isNull);
      expect(parseRequirement(''), isNull);
      expect(parseRequirement('-r other.txt'), isNull);
      final withMarker =
          parseRequirement('click>=8.0; python_version > "3.8"')!;
      expect(withMarker.name, 'click');
      expect(withMarker.satisfiedBy('8.1.0'), isTrue);
      final withExtras = parseRequirement('requests[security]>=2.28')!;
      expect(withExtras.name, 'requests');
      expect(withExtras.satisfiedBy('2.31.0'), isTrue);
    });

    test('names are normalized', () {
      expect(parseRequirement('Pillow==10.0')!.name, 'pillow');
      expect(parseRequirement('my_package==1.0')!.name, 'my-package');
    });
  });

  group('parseRequirementsText', () {
    test('parses a whole file, skipping comments and blanks', () {
      const text = '''
# comment
requests==2.31.0

flask>=2.0
-r other.txt
''';
      final reqs = parseRequirementsText(text);
      expect(reqs.map((r) => r.name), ['requests', 'flask']);
    });
  });

  group('requirementStatus + pipArgFor', () {
    final installed = {'requests': '2.31.0', 'flask': '2.0.3'};

    test('satisfied / missing / mismatch', () {
      expect(
        requirementStatus(
          parseRequirement('requests==2.31.0')!,
          installed,
        ),
        RequirementStatus.satisfied,
      );
      expect(
        requirementStatus(parseRequirement('numpy')!, installed),
        RequirementStatus.missing,
      );
      expect(
        requirementStatus(
          parseRequirement('flask>=3.0')!,
          installed,
        ),
        RequirementStatus.mismatch,
      );
    });

    test('pipArgFor builds the install argument', () {
      expect(pipArgFor(parseRequirement('requests==2.31.0')!),
          'requests==2.31.0');
      expect(
          pipArgFor(parseRequirement('flask>=2.0,<3.0')!), 'flask>=2.0,<3.0');
      expect(pipArgFor(parseRequirement('click')!), 'click');
    });
  });

  group('parseInstalledPackages', () {
    test('parses name==version lines', () {
      final map = parseInstalledPackages(
        'pip==24.0\nrequests==2.31.0\ncharset-normalizer==3.3.2\n',
      );
      expect(map['pip'], '24.0');
      expect(map['requests'], '2.31.0');
      expect(map['charset-normalizer'], '3.3.2');
      expect(map.length, 3);
    });
  });
}
