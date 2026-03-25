import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:iot_monitor_2/device_page.dart';
import 'package:iot_monitor_2/home_page.dart';

void main() {
  runApp(const MyApp());
}

final _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => MyHomePage(
        title: 'Flutter Demo Home Page',
      ),
    ),
    GoRoute(
      path: '/device/:deviceId',
      builder: (context, state) {
        final deviceId = state.pathParameters['deviceId']!;
        return DevicePage(deviceId: deviceId);
      },
    ),
  ],
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Flutter Demo',
      routerConfig: _router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
    );
  }
}
