import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:armoyu_desktop/app/data/models/group_member_model.dart';
import 'package:armoyu_desktop/app/data/models/group_model.dart';
import 'package:armoyu_desktop/app/data/models/internetstatus_model.dart';
import 'package:armoyu_desktop/app/data/models/message_model.dart';
import 'package:armoyu_desktop/app/data/models/room_model.dart';
import 'package:armoyu_desktop/app/data/models/user_model.dart';
import 'package:armoyu_desktop/app/utils/applist.dart';
import 'package:flutter_sound/public/flutter_sound_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mic_stream/mic_stream.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketioController extends GetxController {
  var groups = Rxn<List<Group>>(null);

  late IO.Socket socket;
  var socketChatStatus = false.obs;

  Timer? userListTimer;
  Timer? pingTimer;
  var pingID = "".obs;

  var pingValue = 0.obs; // Ping değerini reaktif hale getirdik
  DateTime? lastPingTime; // Son ping zamanı
  String socketPREFIX = "||SOCKET|| -> ";

  var internetConnectionStatus = InternetType.good.obs;

  late webrtc.RTCVideoRenderer renderer;
  late webrtc.MediaStream localStream;
  var isStreaming = false.obs;

  var isCallingMe = false.obs;
  var whichuserisCallingMe = "".obs;

  final player = AudioPlayer();

  // Stream<List<int>>? _micStream;
  Stream<Uint8List>? _micStream;
  FlutterSoundPlayer? _audioPlayer;
  var isSoundStreaming = false.obs;

  @override
  void onInit() {
    groups.value = AppList.groups;
    renderer = RTCVideoRenderer();
    initRenderer();

    main();

    _initAudioStream();

    startListening();
    super.onInit();
  }

  @override
  void onClose() {
    // Controller kapandığında kaynakları temizle
    stopFetchingUserList();
    stopPing();
    socket.disconnect();
    player.dispose();

    // _audioPlayer!.closeAudioSession();
    super.onClose();
  }

  ////

  Future<void> _initAudioStream() async {
    // FlutterSoundPlayer oluşturuluyor
    _audioPlayer = FlutterSoundPlayer();
    // await _audioPlayer!.openAudioSession();

    // Mikrofon verisi başlatılıyor
    _micStream = await MicStream.microphone(
      // audioSource: AudioSource.DEFAULT,
      sampleRate: 16000, // Örnekleme hızı
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,
    );
  }

  void startListening() {
    if (_micStream != null && !isSoundStreaming.value) {
      isSoundStreaming.value = true;

      _micStream!.listen((data) async {
        // Mikrofon verisini besleyerek anlık ses çalınıyor
        await _audioPlayer!.feedFromStream(data);
      });
    }
  }

  Future<void> stopListening() async {
    if (isSoundStreaming.value) {
      await _audioPlayer!.stopPlayer();

      isSoundStreaming.value = false;
    }
  }

  ///

  main() {
    // Socket.IO'ya bağlanma
    // socket = IO.io('http://mc.armoyu.com:2021', <String, dynamic>{
    socket = IO.io('http://localhost:2021', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    // Her 1 saniyede bir kullanıcı listesini iste
    startFetchingUserList(const Duration(seconds: 1));
    // Her 1 saniyede bir kullanıcı listesini iste

    startPing(const Duration(seconds: 2));
    // Ping değerini güncelle
    socket.on('ping', (data) {
      // Burada data yerine ping zamanı verilmez.
      pingValue.value = data; // Bu satırda hata var
      log('${socketPREFIX}Ping: ${pingValue.value} ms'); // Log ile göster
    });

    // Pong mesajını dinle
    socket.on('pong', (data) {
      // data içinde ping ID'sini al

      String pingId = data['id'];
      if (pingId != pingID.value) {
        log("PING ID eşleşmedi: Beklenen ${pingID.value}, gelen $pingId");

        return;
      }

      DateTime pongReceivedTime = DateTime.now(); // Pong zamanı
      if (lastPingTime != null) {
        // Ping süresini hesapla
        pingValue.value =
            pongReceivedTime.difference(lastPingTime!).inMilliseconds;
        log('Pong yanıtı alındı: $pingId');
        log('Ping süresi: ${pingValue.value} ms');

        if (pingValue.value < 80) {
          internetConnectionStatus.value = InternetType.good;
        } else if (pingValue.value < 200) {
          internetConnectionStatus.value = InternetType.normal;
        } else {
          internetConnectionStatus.value = InternetType.weak;
        }
      }
    });

    socket.on('signaling', (data) {
      // Signaling verilerini dinleme
      print('Signaling verisi alındı: $data');
    });

    socket.on('INCOMING_CALL', (data) {
      // Signaling verilerini dinleme
      print('Kullanıcı Seni Arıyor: $data');
      isCallingMe.value = true;
      whichuserisCallingMe.value = data;
    });
    socket.on('CALL_ACCEPTED', (data) {
      // Signaling verilerini dinleme
      print('Çağrı kabul edildi: $data');
    });
    socket.on('CALL_CLOSED', (data) {
      // Signaling verilerini dinleme
      print('Çağrı reddedildi: $data');
    });

    // Başka biri bağlandığında bildiri al
    socket.on('userConnected', (data) {
      if (data != null) {
        log(socketPREFIX + data.toString());
      }
      log(socketPREFIX + data.toString());
    });
    // Bağlantı başarılı olduğunda
    socket.on('connect', (data) {
      log('${socketPREFIX}Bağlandı');

      if (data != null) {
        log(socketPREFIX + data.toString());
      }
      socketChatStatus.value = true;

      // Kullanıcıyı kaydet
      registerUser(AppList.sessions.first.currentUser.username.toString(),
          AppList.sessions.first.currentUser.toJson());
    });

    // Bağlantı kesildiğinde
    socket.on('disconnect', (data) {
      try {
        log('$socketPREFIX$data');
      } catch (e) {
        log('${socketPREFIX}Hata (disconnect): $e');
      }
      log('${socketPREFIX}Bağlantı kesildi');
      socketChatStatus.value = false;
    });

    // Sunucudan gelen mesajları dinleme
    socket.on('chat', (data) {
      try {
        // print('Sunucudan gelen ham veri: $data');
        Message mm = Message.fromJson(data);
        log("$socketPREFIX${mm.user.value.displayname} - ${mm.message}");

        try {
          var selectedGroup = groups.value!
              .firstWhere((group) => group.groupID == mm.room.value.groupID);
          var selectedRoom = selectedGroup.rooms!.firstWhere(
              (room) => room.name.value == mm.room.value.name.value);

          selectedRoom.message.add(mm);

          log("Mesaj eklendi: ${mm.message.value}");
        } catch (e) {
          log("Mesaj ekleme hatası: $e");
        }
      } catch (e) {
        log('${socketPREFIX}Hata (chat): $e');
      }
    });

    socket.on('USER_LIST', (data) {
      try {
        var json = jsonDecode(data);

        log("${socketPREFIX}Member Count ${json.length}");

        ///Çevrimdışı kullanıcıları kontrol eden listeyi oluştur
        List<User> tempuserlist = [];

        for (var element in json) {
          Room? userRoom;
          if (element['room'] != null) {
            userRoom = Room.fromJson(element['room']);
          }

          User userInfo = User.fromJson(element['clientId']);

          ///Çevrimdışı kullanıcıları kontrol eden listeye ekle
          tempuserlist.add(userInfo);

          // Tüm grupları dolaş
          for (var groupfetch in groups.value!) {
            // Eğer groupmembers null veya boşsa, yeni bir RxList oluştur
            if (groupfetch.groupmembers == null ||
                groupfetch.groupmembers!.isEmpty) {
              groupfetch.groupmembers = RxList<Groupmember>();
            }
            groupfetch.groupmembers!.clear();
            bool kullanicivarmi = groupfetch.groupmembers!.any(
              (element) => element.user.value.username == userInfo.username,
            );

            if (!kullanicivarmi) {
              //Kullanıcı YOKSA LİSTEYE EKLE

              groupfetch.groupmembers!.add(
                Groupmember(
                  user: userInfo.obs,
                  description: "-",
                  status: 0,
                  currentRoom: userRoom?.obs,
                ),
              );
            } else {
              //Kullanıcı VARSA ODASINI GÜNCELLEME İŞLEMLERİ
              var a = groupfetch.groupmembers!.firstWhere(
                (element) => element.user.value.username == userInfo.username,
              );

              a.user.value = userInfo;
              if (userRoom != null) {
                if (userRoom.groupID == groupfetch.groupID) {
                  a.user.value = userInfo;

                  a.currentRoom = userRoom.obs;
                }
              } else {
                a.currentRoom = userRoom?.obs;
              }
            }

            //kullanıcı herhangi bir odada değilse
            if (userRoom != null) {
              try {
                // Kullanıcıların Odaları Listeleniyor
                bool roomExists = groupfetch.rooms!
                    .any((room) => room.name == userRoom!.name);

                // Eğer oda listede yoksa, ekle
                if (!roomExists) {
                  if (userRoom.groupID == groupfetch.groupID) {
                    groupfetch.rooms!.add(userRoom);
                  }
                }

                bool? isUserinRoom;
                for (var room in groupfetch.rooms!) {
                  isUserinRoom = room.currentMembers
                      .any((member) => member.username == userInfo.username);
                }

                //Kullanıcı Odasında mı
                if (isUserinRoom!) {
                  var currentRoom = groupfetch.rooms!.firstWhere(
                    (room) => room.currentMembers
                        .any((member) => member.username == userInfo.username),
                  );

                  if (currentRoom != userRoom) {
                    for (var room in groupfetch.rooms!) {
                      room.currentMembers.removeWhere(
                          (member) => member.username == userInfo.username);
                    }

                    if (userRoom.groupID == groupfetch.groupID) {
                      groupfetch.rooms!
                          .firstWhere((room) => room.name == userRoom!.name)
                          .currentMembers
                          .add(userInfo);
                    }
                  }
                } else {
                  for (var room in groupfetch.rooms!) {
                    room.currentMembers.removeWhere(
                        (member) => member.username == userInfo.username);
                  }
                  if (userRoom.groupID == groupfetch.groupID) {
                    groupfetch.rooms!
                        .firstWhere((room) => room.name == userRoom!.name)
                        .currentMembers
                        .add(userInfo);
                  }
                }
              } catch (e) {
                log("qwwHataq -- $e");
              }
            } else {
              //Odalarda değilse Sil
              for (var room in groupfetch.rooms!) {
                room.currentMembers.removeWhere(
                    (member) => member.username == userInfo.username);
              }
            }
          }
        }

        removeNonMatchingUsers(tempuserlist);
      } catch (e) {
        log('${socketPREFIX}Hata (USER_LIST): $e');
      }
    });

    // Otomatik olarak bağlanma
    socket.connect();

    return this;
  }

  void createRoom(Room room, Group userCurrentgroup) {
    Get.back();
    var currentgroup = findcurrentGroup(userCurrentgroup);

    currentgroup.rooms ??= RxList<Room>();

    currentgroup.rooms!.add(room);
  }

  bool isInRoom(Group userCurrentgroup) {
    var currentgroup = findcurrentGroup(userCurrentgroup);

    // Oda listesi null veya boş mu kontrol edin
    if (currentgroup.rooms == null || currentgroup.rooms!.isEmpty) {
      return false; // Oda yoksa false döner
    }

    return currentgroup.rooms!.any(
      (element) => element.currentMembers.any(
        (element2) =>
            element2.username == AppList.sessions.first.currentUser.username,
      ),
    );
  }

  bool isInRoomanyWhereGroup() {
    return groups.value!.any(
      (element) => element.rooms!.any(
        (element2) => element2.currentMembers.any(
          (element3) =>
              element3.username == AppList.sessions.first.currentUser.username,
        ),
      ),
    );
  }

  Group findcurrentGroup(Group userCurrentgroup) {
    return groups.value!.firstWhere(
      (element) => element == userCurrentgroup,
    );
  }

  Group findanyWhereGroup() {
    return groups.value!.firstWhere(
      (element) => element.rooms!.any(
        (element2) => element2.currentMembers.any(
          (element3) =>
              element3.username == AppList.sessions.first.currentUser.username,
        ),
      ),
    );
  }

  Room? findmyRoom(Group userCurrentgroup) {
    var currentgroup = findcurrentGroup(userCurrentgroup);

    if (isInRoom(userCurrentgroup) == true) {
      return currentgroup.rooms!.firstWhere(
        (element) => element.currentMembers.any(
          (element2) =>
              element2.username == AppList.sessions.first.currentUser.username,
        ),
      );
    }

    return null;
  }

  Room? findmyRoomanyWhereGroup() {
    if (isInRoomanyWhereGroup() == true) {
      for (var group in groups.value!) {
        try {
          // Eğer kullanıcı bu grubun odalarından birindeyse o odayı döndür
          var room = group.rooms!.firstWhere(
            (room) => room.currentMembers.any(
              (member) =>
                  member.username ==
                  AppList.sessions.first.currentUser.username,
            ),
          );
          return room; // Kullanıcının bulunduğu odayı bulunca döndür
        } catch (e) {
          // Odalar arasında bulamazsa, döngü devam eder
          continue;
        }
      }
    }
    return null;
  }

//WEBRTC

  Future<void> initRenderer() async {
    await renderer.initialize();
    await startLocalStream();
  }

  Future<void> startLocalStream() async {
    // Kamera ve mikrofon için medya akışı başlatılıyor
    localStream = await webrtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user', // Ön kamerayı kullanmak için
      },
    });

    // Akış, video render'a atanıyor
    renderer.srcObject = localStream;
    isStreaming.value = true; // Akış başladı
  }

//WEBRTC

  void removeNonMatchingUsers(List<User> tempuserlist) {
    for (var group in groups.value!) {
      // group içindeki memberUserList'i tempUserList ile kıyasla
      group.groupmembers!
          .removeWhere((element) => !tempuserlist.contains(element.user.value));
    }
  }

  // Socket.io ile mesaj gönderme
  void sendMessage(Message data) {
    socket.emit("chat", {data.toJson()});
  }

  // Socket.io birisini arama
  void callUser(User user) {
    socket.emit("CALL_USER", user.username);
  }

  // Socket.io  arama reddetme
  void closecall(String username) {
    socket.emit("CLOSE_CALL", username);

    whichuserisCallingMe.value = "";
    isCallingMe.value = false;
  }

  // Socket.io  arama açma
  void acceptcall(String username) {
    socket.emit("ACCEPT_CALL", username);

    whichuserisCallingMe.value = "";
    isCallingMe.value = false;
  }

  // Kullanıcıyı sunucuya kaydetme
  void registerUser(String name, dynamic clientId) {
    socket.emit('REGISTER', {
      'name': name,
      'clientId': clientId,
    });
  }

  void fetchUserList() {
    // Sunucudan kullanıcı listesi isteme
    socket.emit('USER_LIST');
  }

  void startPing(Duration interval) {
    pingTimer = Timer.periodic(interval, (timer) {
      pingID.value = DateTime.now().millisecondsSinceEpoch.toString() +
          AppList.sessions.first.currentUser.id.toString();
      log('Ping gönderiliyor... ID: ${pingID.value}');

      lastPingTime = DateTime.now();
      socket.emit('ping', {'id': pingID.value}); // ID ile ping gönder
    });
  }

  void stopPing() {
    // Timer durdurma (iptal etme)
    if (pingTimer != null) {
      pingTimer!.cancel();
      pingTimer = null;
    }
  }

  void exitroom() {
    for (var groupInfo in groups.value!) {
      //Oda yoksa bakma
      if (groupInfo.rooms == null) {
        continue;
      }
      for (var room in groupInfo.rooms!) {
        room.currentMembers.removeWhere(
          (member) =>
              member.username == AppList.sessions.first.currentUser.username,
        );
      }
    }
  }

  void changeroom(Room? room) {
    exitroom();

    if (room != null) {
      room.currentMembers.add(AppList.sessions.first.currentUser);
      player.setAsset("assets/sounds/join_room.wav");
      player.play();
    } else {
      player.setAsset("assets/sounds/leave_room.wav");
    }
    try {
      log("oda değiştirildi");

      socket.emit('changeRoom', room?.toJson());
    } catch (e) {
      log("${socketPREFIX}Hata(changeRoom) $e");
    }
  }

  void userUpdate(User user) {
    try {
      log("Bilgiler Güncellendi");

      socket.emit('profileUpdate', user.toJson());
    } catch (e) {
      log("${socketPREFIX}Hata(changeRoom) $e");
    }
  }

////////
  void startFetchingUserList(Duration interval) {
    userListTimer = Timer.periodic(interval, (timer) {
      fetchUserList();
    });
  }

  void stopFetchingUserList() {
    // Timer durdurma (iptal etme)
    if (userListTimer != null) {
      userListTimer!.cancel();
      userListTimer = null;
    }
  }
}
