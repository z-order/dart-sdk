// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// SharedOptions=--enable-experiment=macros

import 'package:expect/expect.dart';

import 'json_serializable.dart';

void main() {
  var rogerJson = {
    'age': 5,
    'name': 'Roger',
    'friends': [
      {
        'age': 7,
        'name': 'Felix',
        'friends': [],
      }
    ],
  };
  var roger = User.fromJson(rogerJson);
  Expect.equals(roger.age, 5);
  Expect.equals(roger.name, 'Roger');
  Expect.equals(roger.friends.length, 1);
  var felix = roger.friends.single;
  Expect.equals(felix.age, 7);
  Expect.equals(felix.name, 'Felix');
  Expect.equals(felix.friends.isEmpty, true);
  Expect.deepEquals(roger.toJson(), rogerJson);

  var rogerAccountJson = {
    ...rogerJson,
    'login': {
      'username': 'roger1',
      'password': 'theGoat',
    },
  };
  (rogerAccountJson['friends'] as dynamic)[0]['login'] = {
    'username': 'felixTheCat',
    'password': '9Lives',
  };
  var rogerAccount = UserAccount.fromJson(rogerAccountJson);
  Expect.equals(rogerAccount.age, 5);
  Expect.equals(rogerAccount.name, 'Roger');
  Expect.equals(rogerAccount.login.username, 'roger1');
  Expect.equals(rogerAccount.login.password, 'theGoat');
  Expect.deepEquals(rogerAccount.toJson(), rogerAccountJson);
}

@JsonSerializable()
class User {
  final int age;
  final String name;
  final List<User> friends;
}

@JsonSerializable()
class UserAccount extends User {
  final Login login;
}

@JsonSerializable()
class Login {
  final String username;
  final String password;
}
