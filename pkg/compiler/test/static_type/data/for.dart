// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Class {
  Class? next;
}

main() {
  for1(null);
  for2(null);
  for3(null);
  for4(null);
}

for1(dynamic c) {
  if (/*dynamic*/ c is Class) {
    /*Class*/ c.next;
    for (/*Class*/ c.next; /*dynamic*/ c != null; /*dynamic*/ c.next) {
      /*dynamic*/ c.next;
      if (/*dynamic*/ c is Class) {
        /*Class*/ c.next;
      }
      c = 0;
    }
    /*dynamic*/ c.next;
  }
}

for2(dynamic c) {
  if (/*dynamic*/ c is Class) {
    /*Class*/ c.next;
    for (/*Class*/ c.next; /*Class*/ c != null; /*Class*/ c.next) {
      /*Class*/ c.next;
    }
    /*Class*/ c.next;
  }
}

for3(dynamic c) {
  /*dynamic*/ c.next;
  for (/*dynamic*/ c.next; /*dynamic*/ c is Class; /*dynamic*/ c.next) {
    /*Class*/ c.next;
    c = 0;
    if (/*dynamic*/ c is Class) {
      /*Class*/ c.next;
    }
  }
  /*dynamic*/ c.next;
}

for4(dynamic c) {
  /*dynamic*/ c.next;
  for (/*dynamic*/ c.next; /*dynamic*/ c is Class; /*Class*/ c.next) {
    /*Class*/ c.next;
  }
  /*dynamic*/ c.next;
}
