import 'package:assorted_layout_widgets/assorted_layout_widgets.dart';
import 'package:bluebubbles/helpers/constants.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/layouts/conversation_view/conversation_view_mixin.dart';
import 'package:bluebubbles/layouts/widgets/contact_avatar_group_widget.dart';
import 'package:bluebubbles/layouts/widgets/contact_avatar_widget.dart';
import 'package:bluebubbles/managers/contact_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/handle.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ContactSelectorOption extends StatelessWidget {
  const ContactSelectorOption({Key? key, required this.item, required this.onSelected, required this.index})
      : super(key: key);
  final UniqueContact item;
  final Function(UniqueContact item) onSelected;
  final int index;

  String getTypeStr(String? type) {
    if (isNullOrEmpty(type)!) return "";
    return " ($type)";
  }

  Future<String> get chatParticipants async {
    if (!item.isChat) return "";

    List<String> formatted = [];
    for (var item in item.chat!.participants) {
      String? contact = ContactManager().getCachedContactSync(item.address ?? "")?.displayName;
      if (contact == null) {
        contact = await formatPhoneNumber(item.address!);
      }

      formatted.add(contact);
    }

    return formatted.join(", ");
  }

  FutureBuilder<String> formattedNumberFuture(String address) {
    return FutureBuilder<String>(
        future: formatPhoneNumber(address),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return this.getTextWidget(context, address);
          }

          return this.getTextWidget(context, snapshot.data);
        });
  }

  Widget getTextWidget(BuildContext context, String? text) {
    return TextOneLine(
      text!,
      style: Theme.of(context).textTheme.subtitle1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool redactedMode = SettingsManager().settings.redactedMode;
    final bool hideInfo = redactedMode && SettingsManager().settings.hideContactInfo;
    final bool generateName = redactedMode && SettingsManager().settings.generateFakeContactNames;
    String title = "";
    if (generateName) {
      if (item.isChat) {
        title = item.chat!.fakeParticipants.length == 1 ? item.chat!.fakeParticipants[0] ?? "Unknown" : "Group Chat";
      } else {
        title = "Person ${index + 1}";
      }
    } else if (!hideInfo) {
      if (item.isChat) {
        title = item.chat!.title ?? "Group Chat";
      } else {
        title = "${item.displayName}${getTypeStr(item.label)}";
      }
    }

    Widget subtitle;
    if (redactedMode) {
      subtitle = getTextWidget(context, "");
    } else if (!item.isChat || item.chat!.participants.length == 1) {
      if (item.address != null) {
        if (!GetUtils.isEmail(item.address!)) {
          subtitle = formattedNumberFuture(item.address!);
        } else {
          subtitle = getTextWidget(context, item.address);
        }
      } else if (item.chat != null &&
          item.chat!.participants[0].address != null &&
          !GetUtils.isEmail(item.chat!.participants[0].address!)) {
        subtitle = formattedNumberFuture(item.chat!.participants[0].address!);
      } else if (GetUtils.isEmail(item.chat!.participants[0].address!)) {
        subtitle = getTextWidget(context, item.chat!.participants[0].address!);
      } else {
        subtitle = getTextWidget(context, "Person ${index + 1}");
      }
    } else {
      subtitle = FutureBuilder<String>(
        future: chatParticipants,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return getTextWidget(context, item.displayName ?? item.address ?? "Person ${index + 1}");
          }

          return getTextWidget(context, snapshot.data);
        },
      );
    }

    return ListTile(
      key: new Key("chat-${item.displayName}"),
      onTap: () => onSelected(item),
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyText1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle,
      leading: !item.isChat
          ? ContactAvatarWidget(
              handle: Handle(address: item.address),
              borderThickness: 0.1,
              editable: false,
            )
          : ContactAvatarGroupWidget(
              chat: item.chat!,
              participants: item.chat!.participants,
              editable: false,
            ),
      trailing: item.isChat
          ? Icon(
              SettingsManager().settings.skin == Skins.iOS ? Icons.arrow_forward_ios : Icons.arrow_forward,
              color: Theme.of(context).primaryColor,
            )
          : null,
    );
  }
}
