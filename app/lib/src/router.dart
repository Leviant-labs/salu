import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/assistant/assistant_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/plan/my_plan_screen.dart';
import 'features/plan/plan_screen.dart';
import 'features/progress/progress_screen.dart';
import 'features/rewards/rewards_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/today/diary_screen.dart';
import 'features/today/today_screen.dart';
import 'features/today/weight_log_screen.dart';
import 'ui_support.dart';

final appRouter = GoRouter(initialLocation:'/today',routes:[
  StatefulShellRoute.indexedStack(builder:(context,state,shell) =>
    HomeShell(navigationShell:shell),branches:[
      StatefulShellBranch(routes:[GoRoute(path:'/today',builder:(context,state) => const TodayScreen())]),
      StatefulShellBranch(routes:[GoRoute(path:'/plan',builder:(context,state) => const MyPlanScreen())]),
      StatefulShellBranch(routes:[GoRoute(path:'/assistant',builder:(context,state) => const AssistantScreen())]),
      StatefulShellBranch(routes:[GoRoute(path:'/progress',builder:(context,state) => const ProgressScreen())]),
    ]),
  GoRoute(path:'/onboarding',builder:(context,state) => const OnboardingScreen(existingUser:true)),
  GoRoute(path:'/diary',builder:(context,state) => _toolPage(context,
      'Diary','Diário',const DiaryScreen())),
  GoRoute(path:'/search',builder:(context,state) => _toolPage(context,
      'Add food','Adicionar alimento',const SearchScreen())),
  GoRoute(path:'/settings',builder:(context,state) => _toolPage(context,
      'Settings','Definições',const SettingsScreen())),
  GoRoute(path:'/plan-tools',builder:(context,state) => _toolPage(context,
      'Recipes and planning tools','Receitas e ferramentas',const PlanScreen())),
  GoRoute(path:'/rewards',builder:(context,state) => _toolPage(context,
      'Rewards','Recompensas',const RewardsScreen())),
  GoRoute(path:'/weight',builder:(context,state) => const WeightLogScreen()),
]);

Widget _toolPage(BuildContext context,String en,String pt,Widget child) =>
    Scaffold(appBar:AppBar(
        leading: BackButton(onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/today');
          }
        }),
        title:Text(tr(context,en,pt))),body:child);

class HomeShell extends StatelessWidget {
  const HomeShell({required this.navigationShell,super.key});
  final StatefulNavigationShell navigationShell;
  @override
  Widget build(BuildContext context) {
    final titles = [tr(context,'Today','Hoje'),tr(context,'My plan','O meu plano'),
      tr(context,'Assistant','Assistente'),tr(context,'Progress','Progresso')];
    return Scaffold(appBar:AppBar(title:Text(titles[navigationShell.currentIndex]),actions:[
      IconButton(tooltip:tr(context,'Add food manually','Adicionar alimento manualmente'),
        icon:const Icon(Icons.search),onPressed:() => context.push('/search')),
      IconButton(tooltip:tr(context,'Profile and settings','Perfil e definições'),
        icon:const Icon(Icons.account_circle_outlined),onPressed:() => context.push('/settings')),
    ]),body:navigationShell,bottomNavigationBar:NavigationBar(
      selectedIndex:navigationShell.currentIndex,
      onDestinationSelected:(index) => navigationShell.goBranch(index,
        initialLocation:index == navigationShell.currentIndex),destinations:[
          NavigationDestination(key:const Key('nav-today'),icon:const Icon(Icons.today_outlined),
            selectedIcon:const Icon(Icons.today),label:titles[0]),
          NavigationDestination(key:const Key('nav-plan'),icon:const Icon(Icons.calendar_month_outlined),
            selectedIcon:const Icon(Icons.calendar_month),label:titles[1]),
          NavigationDestination(key:const Key('nav-assistant'),icon:const Icon(Icons.auto_awesome_outlined),
            selectedIcon:const Icon(Icons.auto_awesome),label:titles[2]),
          NavigationDestination(key:const Key('nav-progress'),icon:const Icon(Icons.insights_outlined),
            selectedIcon:const Icon(Icons.insights),label:titles[3]),
        ]));
  }
}
