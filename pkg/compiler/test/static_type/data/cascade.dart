// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

main() {
  promotedCascade(null);
}

promotedCascade(dynamic value) {
  if (/*dynamic*/ value is List<String>) {
    value =
        '[${(/*List<String>*/ value.. /*invoke: [List<String>]->void*/ sort()). /*invoke: [List<String>]->String*/ join(',')}]';
  }
  return /*dynamic*/ value;
}
