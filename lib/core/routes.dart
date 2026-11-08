import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../views/home_view.dart';
import '../views/chat_view.dart';

abstract class AppRoutes {
  static const home = '/';
  static const chat = '/chat';
}

class AppPages {
  static final pages = [
    GetPage(
      name: AppRoutes.home,
      page: () => const HomeView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => HomeController());
        Get.lazyPut(() => ChatController());
        Get.lazyPut(() => ModelController());
        Get.lazyPut(() => SettingsController());
      }),
    ),
    GetPage(
      name: AppRoutes.chat,
      page: () => const ChatView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => ChatController());
      }),
    ),
  ];
}
