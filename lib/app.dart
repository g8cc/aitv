import 'package:flutter/material.dart';

import 'features/home/home_page.dart';

class AiTvApp extends StatelessWidget {
  const AiTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Momo 英语小伙伴',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFB74D)),
        useMaterial3: true,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(72, 48),
            textStyle: const TextStyle(fontSize: 17),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
