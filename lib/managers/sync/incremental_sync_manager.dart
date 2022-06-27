import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/helpers/logger.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/managers/sync/sync_manager.dart';
import 'package:bluebubbles/repository/models/settings.dart';
import 'package:bluebubbles/socket_manager.dart';
import 'package:dio/dio.dart' as dio;
import 'package:get/get.dart';

import '../../repository/models/models.dart';


class IncrementalSyncManager extends SyncManager {
  final tag = 'IncrementalSyncManager';

  int startTimestamp;

  int? endTimestamp;

  int batchSize;

  int maxMessages;

  int chatsSynced = 0;

  int messagesSynced = 0;

  String? chatGuid;

  bool saveDate;

  Function? onComplete;

  int get syncStart => endTimestamp ?? DateTime.now().millisecondsSinceEpoch;

  IncrementalSyncManager(this.startTimestamp,
      {
        this.endTimestamp,
        this.batchSize = 1000,
        this.maxMessages = 10000,
        this.chatGuid,
        this.saveDate = true,
        this.onComplete,
        bool saveLogs = false
      }) : super("Incremental", saveLogs: saveLogs);

  @override
  Future<void> start() async {
    if (completer != null && !completer!.isCompleted) {
      return completer!.future;
    } else {
      completer = Completer<void>();
    }

    super.start();
    addToOutput("Starting incremental sync for messages since: $startTimestamp - $syncStart");

    // 0: Hit API endpoint to check for updated messages
    // 1: If no new updated messages, complete the sync
    // 2: If there are new messages, fetch them by page
    // 3: Enumerate the chats into cache
    // 4: Sync the chats
    // 5: Merge synced chats back into cache
    // 6: For each chat, bulk sync the messages

    // Check the server version and page differently based on that.
    // In < 1.2.0, the message query API endpoint was a bit broken.
    // It would not include messages with the text being null. As such,
    // the count can be slightly lower than the real count. To account
    // for this, we just multiple the count by 2. This way, even if all
    // the messages have a null text, we can still account for them when we fetch.
    int serverVersion = await SettingsManager().getServerVersionCode();
    // TODO: Fix to < when done testing
    bool isBugged = serverVersion <= 142;  // Server: v1.2.0
    print(serverVersion);

    // 0: Hit API endpoint to check for updated messages
    dio.Response<dynamic> uMessageCountRes = await api.messageCount(
      after: DateTime.fromMillisecondsSinceEpoch(startTimestamp),
      before: DateTime.fromMillisecondsSinceEpoch(syncStart),
    );

    // 1: If no new updated messages, complete the sync
    int count = uMessageCountRes.data['data']['total'];
    print("The count: $count");

    // Manually set/modify the count if we are on a bugged server
    if (isBugged) {
      // If count is 0, fetch 1 page.
      // If > 0, fetch count * 2 to account for any possible null texts
      if (count == 0) {
        count = batchSize;
      } else {
        count = count * 2;
      }
    }

    addToOutput('Found $count updated message(s) to sync...');
    if (count == 0) {
      return await complete();
    }

    int pages = (count / batchSize).ceil();

    // 2: If there are new messages, fetch them by page
    int syncedMessages = 0;
    Map<String, Chat> syncedChats = {};
    for (var i = 0; i < pages; i++) {
      addToOutput('Fetching page ${i + 1} of $pages...');
      dio.Response<dynamic> messages = await api.messages(
        after: startTimestamp,
        before: syncStart,
        offset: i * batchSize,
        limit: batchSize,
        withQuery: ["chats"]
      );

      int messageCount = messages.data['data'].length;
      addToOutput('Page ${i + 1} returned $messageCount message(s)...', level: LogLevel.DEBUG);

      // If we don't get any messages back, break out so we can complete.
      if (messageCount == 0) break;

      // 3: Enumerate the chats into cache
      Map<String, Chat> chatCache = {};
      Map<String, List<Message>> messagesToSync = {};
      for (var msgData in messages.data['data'] as List<dynamic>) {
        for (var chat in msgData['chats']) {
          if (!chatCache.containsKey(chat['guid'])) {
            chatCache[chat['guid']] = Chat.fromMap(chat);
          }

          if (!messagesToSync.containsKey(chat['guid'])) {
            messagesToSync[chat['guid']] = [Message.fromMap(msgData)];
          } else {
            messagesToSync[chat['guid']]!.add(Message.fromMap(msgData));
          }
        }
      }

      // 4: Sync the chats
      List<Chat> theChats = await Chat.bulkSyncChats(chatCache.values.toList());

      print('chats: ${theChats.length}');
      
      // 5: Merge synced chats back into cache
      for (var chat in theChats) {
        if (!chatCache.containsKey(chat.guid)) continue;
        chatCache[chat.guid] = chat;
      }

      // Add everything to the global cache
      syncedChats.addAll(chatCache);

      // 6: For each chat, bulk sync the messages
      for (var item in messagesToSync.entries) {
        Chat? theChat = chatCache[item.key];
        if (theChat == null) continue;

        List<Message> s = await Chat.bulkSyncMessages(theChat, item.value);
        syncedMessages += s.length;
        setProgress(syncedMessages, count);
      }

      print('messages: $syncedMessages');

      // If the count of the results is less than the batch size, it means
      // we reached the end of the data (otherwise, it would return the batch size)
      if (messageCount < batchSize) break;
    }

    // If we've synced chats, we should also update the latest message
    if (syncedChats.isNotEmpty) {
      List<Chat> updatedChats = await Chat.syncLatestMessages(syncedChats.values.toList());

    }

    // End the sync
    await complete();
  }

  // @override
  // Future<void> start() async {
  //   if (completer != null && !completer!.isCompleted) {
  //     return completer!.future;
  //   } else {
  //     completer = Completer<void>();
  //   }

  //   super.start();

  //   // Store the time we started syncing
  //   RxInt lastSync = SettingsManager().settings.lastIncrementalSync;
  //   syncStart = endTimestamp ?? DateTime.now().millisecondsSinceEpoch;
  //   addToOutput("Starting incremental sync for messages since: ${lastSync.value} - $syncStart");

  //   // 0: Hit API endpoint to check for updated messages
  //   // 1: If no new updated messages, complete the sync
  //   // 2: If there are new messages, fetch them by page
  //   // 3: Enumerate the chats into cache
  //   // 4: Sync the chats
  //   // 5: Merge synced chats back into cache
  //   // 6: For each chat, bulk sync the messages

  //   // 0: Hit API endpoint to check for updated messages
  //   dio.Response<dynamic> uMessageCountRes = await api.messageCount(
  //     after: DateTime.fromMillisecondsSinceEpoch(lastSync.value),
  //     before: DateTime.fromMillisecondsSinceEpoch(syncStart!),
  //   );

  //   // 1: If no new updated messages, complete the sync
  //   int count = uMessageCountRes.data['data']['total'];
  //   addToOutput('Found $count updated message(s) to sync...');
  //   if (count == 0) {
  //     return await complete();
  //   }

  //   // 2: If there are new messages, fetch them by page
  //   int pages = (count / batchSize).ceil();
  //   setProgress(0, count);

  //   int syncedMessages = 0;
  //   for (var i = 0; i < pages; i++) {
  //     dio.Response<dynamic> messages = await api.messages(
  //       after: lastSync.value,
  //       before: syncStart!,
  //       offset: i * batchSize,
  //       limit: batchSize,
  //       withQuery: ["chats"]
  //     );

  //     print("Messages: ${messages.data['data'].length}");

  //     // 3: Enumerate the chats into cache
  //     Map<String, Chat> chatCache = {};
  //     Map<String, List<Message>> messagesToSync = {};
  //     for (var msgData in messages.data['data'] as List<dynamic>) {
  //       for (var chat in msgData['chats']) {
  //         if (!chatCache.containsKey(chat['guid'])) {
  //           chatCache[chat['guid']] = Chat.fromMap(chat);
  //         }

  //         if (!messagesToSync.containsKey(chat['guid'])) {
  //           messagesToSync[chat['guid']] = [Message.fromMap(msgData)];
  //         } else {
  //           messagesToSync[chat['guid']]!.add(Message.fromMap(msgData));
  //         }
  //       }
  //     }

  //     // 4: Sync the chats
  //     List<Chat> syncedChats = await Chat.bulkSyncChats(chatCache.values.toList());
  //     print("Chats: ${syncedChats.length}");
  //     print(messagesToSync);
      
  //     // 5: Merge synced chats back into cache
  //     for (var chat in syncedChats) {
  //       if (!chatCache.containsKey(chat.guid)) continue;
  //       chatCache[chat.guid] = chat;
  //     }

  //     // 6: For each chat, bulk sync the messages
  //     for (var item in messagesToSync.entries) {
  //       Chat? theChat = chatCache[item.key];
  //       if (theChat == null) continue;

  //       List<Message> s = await Chat.bulkSyncMessages(theChat, item.value);
  //       print("RET: ${s.length}");
  //       syncedMessages += s.length;
  //       setProgress(syncedMessages, count);
  //     }
  //   }

  //   print("$syncedMessages / $count");

  //   // End the sync
  //   await complete();
  // }

  @override
  Future<void> complete() async {
    // Once we have added everything, save the last sync date
    if (saveDate) {
      addToOutput("Saving last sync date: $syncStart");

      Settings _settingsCopy = SettingsManager().settings;
      _settingsCopy.lastIncrementalSync.value = syncStart!;
      await SettingsManager().saveSettings(_settingsCopy);
    }

    // Call this first so listeners can react before any
    // "heavier" calls are made
    await super.complete();

    if (SettingsManager().settings.showIncrementalSync.value) {
      showSnackbar('Success', '🔄 Incremental sync complete 🔄');
    }

    if (onComplete != null) {
      onComplete!();
    }
  }
}
