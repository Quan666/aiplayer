import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'media_identity.dart';

/// Preview membership must include the complete directory structure.
const directoryPreviewMembershipRevision = 1;

/// Local and synchronized previews must use the same cache format and inputs.
String directoryPreviewContext({
  required Map? source,
  required String strategy,
  required String aiContext,
}) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          'catalog-v7',
          directoryPreviewMembershipRevision,
          mediaIdentityRevision,
          source,
          strategy,
          aiContext,
        ]),
      ),
    )
    .toString();
