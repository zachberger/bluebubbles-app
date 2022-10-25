import 'package:bluebubbles/core/managers/chat/chat_manager.dart';
import 'package:bluebubbles/helpers/models/extensions.dart';
import 'package:bluebubbles/utils/general_utils.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

ChatsService chats = Get.isRegistered<ChatsService>() ? Get.find<ChatsService>() : Get.put(ChatsService());

class ChatsService extends GetxService {
  static const batchSize = 15;

  final RxBool hasChats = false.obs;
  final RxBool loadedChatBatch = false.obs;
  final RxList<Chat> chats = <Chat>[].obs;

  final List<Handle> webCachedHandles = [];

  Future<void> init() async {
    Logger.info("Fetching chats...", tag: "ChatBloc");
    int count = Chat.count() ?? (await http.chatCount().catchError((err) {
      Logger.info("Error when fetching chat count!", tag: "ChatBloc");
    })).data['data']['total'];

    if (count != 0) {
      hasChats.value = true;
    } else {
      loadedChatBatch.value = true;
      return;
    }

    final newChats = <Chat>[];
    final batches = (count < batchSize) ? batchSize : (count / batchSize).ceil();

    for (int i = 0; i < batches; i++) {
      List<Chat> _chats;
      if (kIsWeb) {
        _chats = await ChatManager().getChats(withLastMessage: true, limit: batchSize, offset: i * batchSize);
      } else {
        _chats = await Chat.getChats(limit: batchSize, offset: i * batchSize);
      }

      for (Chat c in _chats) {
        ChatManager().createChatController(c);
      }
      newChats.addAll(_chats);

      if (kIsWeb) {
        webCachedHandles.addAll(chats.map((e) => e.participants).flattened.toList());
        final ids = webCachedHandles.map((e) => e.address).toSet();
        webCachedHandles.retainWhere((element) => ids.remove(element.address));
      }

      newChats.sort(Chat.sort);
      chats.value = newChats;
      loadedChatBatch.value = true;
    }

    Logger.info("Finished fetching chats (${chats.length}).", tag: "ChatBloc");
    // update share targets
    for (Chat c in chats.where((e) => !isNullOrEmpty(e.title)!).take(4)) {
      await mcs.invokeMethod("push-share-targets", {
        "title": c.title,
        "guid": c.guid,
        "icon": await avatarAsBytes(
          isGroup: c.isGroup(),
          participants: c.participants,
          chatGuid: c.guid,
          quality: 256
        ),
      });
    }
  }

  void sort() {
    chats.sort(Chat.sort);
  }

  void updateChat(Chat updated) {
    final index = chats.indexWhere((e) => updated.guid == e.guid);
    final toUpdate = chats[index];
    bool shouldSort = toUpdate.isArchived != updated.isArchived
        || toUpdate.isPinned != updated.isPinned
        || toUpdate.pinIndex != updated.pinIndex
        || toUpdate.latestMessageDate != updated.latestMessageDate;
    chats[index] = updated.merge(toUpdate);
    if (shouldSort) sort();
  }

  void addChat(Chat toAdd) {
    chats.add(toAdd);
    ChatManager().createChatController(toAdd);
    sort();
  }

  void removeChat(Chat toRemove) {
    final index = chats.indexWhere((e) => toRemove.guid == e.guid);
    chats.removeAt(index);
  }

  void markAllAsRead() {
    chats.where((element) => element.hasUnreadMessage!).forEach((element) {
      element.toggleHasUnread(false);
      mcs.invokeMethod("clear-chat-notifs", {"chatGuid": element.guid});
    });
  }

  void updateChatPinIndex(int oldIndex, int newIndex) {
    final items = chats.bigPinHelper(true);
    final item = items[oldIndex];

    // Remove the item at the old index, and re-add it at the newIndex
    // We dynamically subtract 1 from the new index depending on if the newIndex is > the oldIndex
    items.removeAt(oldIndex);
    items.insert(newIndex + (oldIndex < newIndex ? -1 : 0), item);

    // Move the pinIndex for each of the chats, and save the pinIndex in the DB
    items.forEachIndexed((i, e) {
    e.pinIndex = i;
    e.save(updatePinIndex: true);
    });
  }

  void removePinIndices() {
    chats.bigPinHelper(true).where((e) => e.pinIndex != null).forEach((element) {
      element.pinIndex = null;
      element.save(updatePinIndex: true);
    });
  }
}