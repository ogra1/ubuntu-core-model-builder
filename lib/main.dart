import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import 'pages/home_page.dart';

void main() {
  runApp(const ModelBuilderApp());
}

class ModelBuilderApp extends StatelessWidget {
  const ModelBuilderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return YaruTheme(
      builder: (context, yaru, child) {
        return MaterialApp(
          title: 'Ubuntu Core Model Builder',
          theme: yaru.theme,
          darkTheme: yaru.darkTheme,
          debugShowCheckedModeBanner: false,
          home: const HomePage(),
        );
      },
    );
  }
}
