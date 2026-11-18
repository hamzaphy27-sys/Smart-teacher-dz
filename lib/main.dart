import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SmartTeacherApp()));
}

class SmartTeacherApp extends StatelessWidget {
  const SmartTeacherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Teacher DZ',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      locale: const Locale('ar', 'DZ'),
      supportedLocales: const [
        Locale('ar', 'DZ'),
        Locale('fr', 'FR'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeScreen(),
    );
  }
}
