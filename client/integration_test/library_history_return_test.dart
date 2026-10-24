import 'package:integration_test/integration_test.dart';

import '../test/library_history_return_test.dart' as history_return;

// Run with flutter drive --profile -d linux and the common
// test_driver/artwork_performance_driver.dart. The explicit mobile themes in
// this suite work in profile mode, unlike debugDefaultTargetPlatformOverride.
// Pass --dart-define=HISTORY_RETURN_ARTIFACT_DIR=/absolute/path to capture the
// bundled font and library before assertions on each return.
// Desktop software rendering verifies layout/errors, not Android frame rates.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  history_return.main();
}
