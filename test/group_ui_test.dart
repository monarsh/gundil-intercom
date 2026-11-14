import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/peer_list.dart';

void main() {
  testWidgets('groups show in the list and can be created', (tester) async {
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
      groups: [
        Group(
          id: 'g1',
          name: 'Family',
          members: {'me': 'Me', 'x': 'Xavier', 'y': 'Yasmin'},
          updated: 1,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerList(service: service, onAddPeer: () {}),
        ),
      ),
    );
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('0 of 2 online · Xavier, Yasmin'), findsOneWidget);

    await tester.tap(find.text('Family'));
    expect(service.target, const GroupTarget('g1'));

    // Edit shows the members, even offline ones we never met.
    await tester.longPress(find.text('Family'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Edit group'), findsOneWidget);
    expect(find.text('Xavier'), findsOneWidget);
    await tester.tap(find.text('Xavier'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(service.group('g1')!.members.keys, unorderedEquals(['me', 'y']));

    // A new group needs a name and a member.
    await tester.tap(find.text('New'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('New group'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(find.text('Give the group a name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 500));
  });
}
