import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:android_id/android_id.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const T = {
  'fa': {'on': 'متصل شد', 'off': 'برای اتصال بزنید', 'conn': 'در حال اتصال...', 'configs': 'کانفیگ‌ها', 'add': 'افزودن', 'file': 'فایل', 'paste': 'چسباندن', 'empty': 'کانفیگی نیست. از + یا QR اضافه کنید', 'settings': 'تنظیمات', 'lang': 'زبان', 'theme': 'تم', 'mode': 'حالت پروکسی (بدون VPN)', 'dev': 'شناسه دستگاه', 'backup': 'پشتیبان‌گیری', 'restore': 'بازیابی', 'sure': 'همه حذف بشن؟', 'ok': 'تأیید', 'no': 'لغو', 'added': 'اضافه شد', 'fail': 'خطا در دریافت', 'copied': 'کپی شد', 'auto': 'خودکار (بهترین پینگ)'},
  'en': {'on': 'Connected', 'off': 'Tap to connect', 'conn': 'Connecting...', 'configs': 'Configs', 'add': 'Add', 'file': 'File', 'paste': 'Paste', 'empty': 'No configs. Add with + or QR', 'settings': 'Settings', 'lang': 'Language', 'theme': 'Theme', 'mode': 'Proxy mode (no VPN)', 'dev': 'Device ID', 'backup': 'Backup', 'restore': 'Restore', 'sure': 'Delete everything?', 'ok': 'OK', 'no': 'Cancel', 'added': 'added', 'fail': 'Download failed', 'copied': 'Copied', 'auto': 'Auto (best ping)'},
  'ar': {'on': 'متصل', 'off': 'اضغط للاتصال', 'conn': 'جارٍ الاتصال...', 'configs': 'التكوينات', 'add': 'إضافة', 'file': 'ملف', 'paste': 'لصق', 'empty': 'لا توجد تكوينات. أضف عبر + أو QR', 'settings': 'الإعدادات', 'lang': 'اللغة', 'theme': 'السمة', 'mode': 'وضع البروكسي (بدون VPN)', 'dev': 'معرّف الجهاز', 'backup': 'نسخ احتياطي', 'restore': 'استعادة', 'sure': 'حذف الكل؟', 'ok': 'تأكيد', 'no': 'إلغاء', 'added': 'تمت الإضافة', 'fail': 'فشل التحميل', 'copied': 'تم النسخ', 'auto': 'تلقائي (أفضل بينغ)'},
};
String t(String k) => T[c.lang]![k]!;

// 0-6 colors, 7 = black theme, 8 = white theme
const cols = [Color(0xFFA855F7), Color(0xFF3B82F6), Color(0xFF22C55E), Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFEC4899), Color(0xFF06B6D4), Colors.white, Color(0xFF111111)];
final mk = GlobalKey<ScaffoldMessengerState>();
void toast(String m) => mk.currentState?.showSnackBar(SnackBar(content: Text(m)));

class Cfg {
  String r, l, g;
  int ping;
  Cfg(this.r, this.l, this.g, [this.ping = 0]);
  Map<String, dynamic> toJson() => {'r': r, 'l': l, 'g': g};
  factory Cfg.fromJson(Map m) => Cfg(m['r'], m['l'], m['g']);
}

class Ctl extends ChangeNotifier {
  late SharedPreferences p;
  late FlutterV2ray v2;
  List<Cfg> cfgs = [];
  List<String> subs = [];
  String? sel;
  int theme = 0, ping = 0, dl = 0, ul = 0;
  String lang = 'fa', state = 'DISCONNECTED', devId = '';
  bool proxyOnly = false;

  bool get light => theme == 8;
  Color get acc => cols[theme];
  Color get ic => light ? Colors.black : acc;
  Color get bg => light ? Colors.white : Colors.black;
  Color get fg => light ? Colors.black : Colors.white;

  Cfg? get cur {
    for (final x in cfgs) {
      if (x.l == sel) return x;
    }
    final ok = cfgs.where((x) => x.ping > 0).toList();
    return ok.isNotEmpty ? ok.first : (cfgs.isEmpty ? null : cfgs.first);
  }

  Future<void> init() async {
    p = await SharedPreferences.getInstance();
    try {
      cfgs = (jsonDecode(p.getString('cfgs') ?? '[]') as List).map((e) => Cfg.fromJson(e)).toList();
    } catch (_) {}
    subs = p.getStringList('subs') ?? [];
    sel = p.getString('sel');
    theme = p.getInt('theme') ?? 0;
    lang = p.getString('lang') ?? 'fa';
    proxyOnly = p.getBool('proxy') ?? false;
    try {
      devId = await AndroidId().getId() ?? '';
    } catch (_) {}
    v2 = FlutterV2ray(onStatusChanged: (s) {
      final was = state;
      state = s.state;
      dl = s.downloadSpeed;
      ul = s.uploadSpeed;
      if (state == 'CONNECTED' && was != 'CONNECTED') Future.delayed(const Duration(seconds: 2), measure);
      if (state != 'CONNECTED') ping = 0;
      notifyListeners();
    });
    await v2.initializeV2Ray();
    Timer.periodic(const Duration(seconds: 5), (_) => measure());
    refresh();
  }

  bool measuring = false;
  Future<void> measure() async {
    if (state != 'CONNECTED' || measuring) return;
    measuring = true;
    try {
      ping = await v2.getConnectedServerDelay();
    } catch (_) {}
    measuring = false;
    notifyListeners();
  }

  DateTime? lastUpd;
  Future<void> refresh() async {
    final n = DateTime.now();
    if (lastUpd != null && n.difference(lastUpd!).inSeconds < 30) return;
    lastUpd = n;
    await updateSubs();
    testAll();
  }

  Future<void> save() async {
    // Await every write so config changes are committed before the operation completes.
    await p.setString('cfgs', jsonEncode(cfgs.map((x) => x.toJson()).toList()));
    await p.setStringList('subs', List<String>.from(subs));
    if (sel != null) {
      await p.setString('sel', sel!);
    } else {
      await p.remove('sel');
    }
    await p.setInt('theme', theme);
    await p.setString('lang', lang);
    await p.setBool('proxy', proxyOnly);
  }

  Future<void> set(void Function() f) async {
    f();
    notifyListeners();
    await save();
  }

  String dec(String s) {
    s = s.trim();
    if (s.contains('://')) return s;
    try {
      return utf8.decode(base64.decode(base64.normalize(s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/'))));
    } catch (_) {
      return s;
    }
  }

  bool addOne(String l, String g) {
    if (!RegExp(r'^(vmess|vless|trojan|ss|socks)://').hasMatch(l) || cfgs.any((x) => x.l == l)) return false;
    try {
      final u = FlutterV2ray.parseFromURL(l);
      cfgs.add(Cfg(u.remark.isEmpty ? l.substring(0, 18) : u.remark, l, g));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> fetchSub(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'v2rayNG/1.8.5'}).timeout(const Duration(seconds: 25));
      final ls = dec(r.body).split(RegExp(r'\s+')).where((e) => e.contains('://')).toList();
      if (ls.isEmpty) return 0; // keep old configs if update returned nothing
      cfgs.removeWhere((x) => x.g == url);
      var n = 0;
      for (final l in ls) {
        if (addOne(l, url)) n++;
      }
      return n;
    } catch (_) {
      return -1; // keep old configs on error
    }
  }

  Future<void> updateSubs() async {
    for (final u in List.of(subs)) {
      await fetchSub(u);
    }
    await set(() {});
  }

  Future<void> addText(String s) async {
    var n = 0, bad = false;
    for (final l in dec(s).split(RegExp(r'\s+'))) {
      if (l.startsWith('http')) {
        if (!subs.contains(l)) subs.add(l);
        final k = await fetchSub(l);
        if (k < 0) {
          bad = true;
        } else {
          n += k;
        }
      } else if (addOne(l, 'manual')) {
        n++;
      }
    }
    await set(() {});
    toast(bad ? t('fail') : '$n ${t('added')}');
    if (n > 0) testAll();
  }

  Future<void> testAll() async {
    final q = List<Cfg>.of(cfgs);
    var i = 0;
    Future<void> w() async {
      while (i < q.length) {
        final x = q[i++];
        try {
          x.ping = await v2.getServerDelay(config: FlutterV2ray.parseFromURL(x.l).getFullConfiguration());
        } catch (_) {
          x.ping = -1;
        }
        notifyListeners();
      }
    }

    await Future.wait(List.generate(4, (_) => w()));
    int k(Cfg x) => x.ping > 0 ? x.ping : (x.ping == 0 ? 50000 : 99999);
    await set(() => cfgs.sort((a, b) => k(a).compareTo(k(b))));
  }

  Future<void> toggle() async {
    if (state == 'CONNECTED' || state == 'CONNECTING') {
      v2.stopV2Ray();
      return;
    }
    final x = cur;
    if (x == null) {
      toast(t('empty'));
      return;
    }
    if (!proxyOnly && !await v2.requestPermission()) return;
    final u = FlutterV2ray.parseFromURL(x.l);
    v2.startV2Ray(remark: u.remark, config: u.getFullConfiguration(), proxyOnly: proxyOnly, bypassSubnets: null, blockedApps: null);
  }
}

final c = Ctl();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await c.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext x) => ListenableBuilder(
      listenable: c,
      builder: (_, __) => MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'ERFAN VPN',
            scaffoldMessengerKey: mk,
            theme: ThemeData(brightness: c.light ? Brightness.light : Brightness.dark, scaffoldBackgroundColor: c.bg, colorScheme: ColorScheme.fromSeed(seedColor: c.acc, brightness: c.light ? Brightness.light : Brightness.dark)),
            builder: (_, w) => Directionality(textDirection: c.lang == 'en' ? TextDirection.ltr : TextDirection.rtl, child: w!),
            home: const Shell(),
          ));
}

Widget ib(IconData i, VoidCallback f) => GestureDetector(
    onTap: f,
    child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(color: c.light ? Colors.black87 : Colors.black54, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.acc, width: 2), boxShadow: [BoxShadow(color: c.acc.withOpacity(.5), blurRadius: 12)]),
        child: Icon(i, color: Colors.white, size: 30)));

Widget card(String t, String v, String u, Color col) => Expanded(
    child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(color: c.light ? Colors.black87 : Colors.black54, borderRadius: BorderRadius.circular(18), border: Border.all(color: col, width: 2), boxShadow: [BoxShadow(color: col.withOpacity(.4), blurRadius: 14)]),
        child: Column(children: [
          Text(t, style: TextStyle(color: col, fontWeight: FontWeight.w600)),
          Text(v, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
          Text(u, style: TextStyle(color: col)),
        ])));

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _S();
}

class _S extends State<Shell> with WidgetsBindingObserver {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState st) {
    if (st == AppLifecycleState.resumed) c.refresh();
  }

  @override
  Widget build(BuildContext x) => ListenableBuilder(
      listenable: c,
      builder: (_, __) => Scaffold(
              body: Stack(children: [
            Positioned.fill(
                child: Opacity(
                    opacity: c.light ? .12 : .55,
                    child: Image.asset('assets/bg.png', fit: BoxFit.cover, color: c.theme == 0 ? null : (c.theme >= 7 ? Colors.grey : c.acc), colorBlendMode: c.theme >= 7 ? BlendMode.saturation : BlendMode.hue))),
            SafeArea(child: Column(children: [Expanded(child: tab == 0 ? home(x) : lst(x)), nav()])),
          ])));

  Widget nav() => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        for (final i in [0, 1])
          Expanded(
              child: GestureDetector(
                  onTap: () => setState(() => tab = i),
                  child: Container(
                      height: 58,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(color: c.light ? Colors.black12 : Colors.black54, borderRadius: BorderRadius.circular(30), border: Border.all(color: c.acc, width: tab == i ? 3 : 1), boxShadow: [BoxShadow(color: c.acc.withOpacity(tab == i ? .6 : .15), blurRadius: 16)]),
                      child: Icon(i == 0 ? Icons.home_rounded : Icons.grid_view_rounded, size: 32, color: tab == i ? c.ic : Colors.grey)))),
      ]));

  Widget home(BuildContext x) {
    final on = c.state == 'CONNECTED', busy = c.state == 'CONNECTING';
    final cp = c.cur?.ping ?? 0;
    final pv = on && c.ping > 0 ? '${c.ping}' : (cp > 0 ? '$cp' : '--');
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ib(Icons.settings, () => Navigator.push(x, MaterialPageRoute(builder: (_) => const SettingsPage()))),
            const Spacer(),
            ib(Icons.qr_code_scanner, () => scan(x)),
            const SizedBox(width: 10),
            ib(Icons.add, () => addDialog(x)),
          ])),
      ShaderMask(
          shaderCallback: (r) => LinearGradient(colors: [c.fg, c.acc, c.fg]).createShader(r),
          child: const Text('ERFAN VPN', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, color: Colors.white))),
      const Spacer(),
      GestureDetector(
          onTap: c.toggle,
          child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 170,
              height: 170,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.light ? Colors.white : Colors.black87, border: Border.all(color: c.ic, width: 4), boxShadow: [BoxShadow(color: c.acc.withOpacity(on ? .8 : .3), blurRadius: on ? 60 : 22, spreadRadius: on ? 10 : 2)]),
              child: Icon(Icons.power_settings_new, size: 84, color: busy ? Colors.amber : c.ic))),
      const SizedBox(height: 18),
      Text(on ? t('on') : (busy ? t('conn') : t('off')), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text('${c.cur?.r ?? t('auto')}  ·  ${c.proxyOnly ? 'Proxy' : 'VPN'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
      const Spacer(),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            card('Ping', pv, 'ms', const Color(0xFF22E07A)),
            card('Download', (c.dl / 1024).toStringAsFixed(1), 'KB/s', const Color(0xFF3B9BFF)),
            card('Upload', (c.ul / 1024).toStringAsFixed(1), 'KB/s', const Color(0xFFFF3B4D)),
          ])),
      const SizedBox(height: 16),
    ]);
  }

  Widget lst(BuildContext x) => Column(children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Padding(padding: const EdgeInsets.all(8), child: Text(t('configs'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              const Spacer(),
              IconButton(icon: const Icon(Icons.speed), onPressed: c.testAll),
              IconButton(
                  icon: const Icon(Icons.sync),
                  onPressed: () async {
                    await c.updateSubs();
                    c.testAll();
                  }),
              IconButton(icon: const Icon(Icons.delete_sweep), onPressed: () => sure(x)),
            ])),
        Expanded(
            child: c.cfgs.isEmpty
                ? Center(child: Text(t('empty')))
                : ListView(children: [
                    for (final e in c.cfgs)
                      Dismissible(
                          key: ValueKey(e.l),
                          onDismissed: (_) => c.set(() => c.cfgs.remove(e)),
                          child: ListTile(
                              leading: Icon(e == c.cur ? Icons.check_circle : Icons.circle_outlined, color: c.ic),
                              title: Text(e.r, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(e.g == 'manual' ? 'manual' : (Uri.tryParse(e.g)?.host ?? '')),
                              trailing: Text(e.ping > 0 ? '${e.ping} ms' : (e.ping < 0 ? '✕' : '…'), style: TextStyle(fontWeight: FontWeight.bold, color: e.ping < 0 ? Colors.red : (e.ping > 400 ? Colors.orange : Colors.green))),
                              onTap: () => c.set(() => c.sel = e.l))),
                  ])),
      ]);

  void sure(BuildContext x) => showDialog(
      context: x,
      builder: (d) => AlertDialog(title: Text(t('sure')), actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(t('no'))),
            FilledButton(
                onPressed: () {
                  c.set(() {
                    c.cfgs.clear();
                    c.subs.clear();
                    c.sel = null;
                  });
                  Navigator.pop(d);
                },
                child: Text(t('ok'))),
          ]));

  void addDialog(BuildContext x) {
    final tc = TextEditingController();
    showDialog(
        context: x,
        builder: (d) => AlertDialog(
                title: Text(t('add')),
                content: TextField(controller: tc, maxLines: 5, decoration: const InputDecoration(hintText: 'vless:// vmess:// trojan:// ss://\nhttps://subscription')),
                actions: [
                  TextButton(
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles();
                        final path = r?.files.single.path;
                        if (d.mounted) Navigator.pop(d);
                        if (path != null) await c.addText(await File(path).readAsString());
                      },
                      child: Text(t('file'))),
                  TextButton(
                      onPressed: () async {
                        final v = await Clipboard.getData('text/plain');
                        tc.text = v?.text ?? '';
                      },
                      child: Text(t('paste'))),
                  FilledButton(
                      onPressed: () {
                        Navigator.pop(d);
                        c.addText(tc.text);
                      },
                      child: Text(t('add'))),
                ]));
  }

  Future<void> scan(BuildContext x) async {
    var done = false;
    final r = await Navigator.push<String>(
        x,
        MaterialPageRoute(
            builder: (bx) => Scaffold(
                appBar: AppBar(),
                body: MobileScanner(onDetect: (cap) {
                  final v = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
                  if (v != null && !done) {
                    done = true;
                    Navigator.pop(bx, v);
                  }
                }))));
    if (r != null) await c.addText(r);
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext x) => ListenableBuilder(
      listenable: c,
      builder: (_, __) => Scaffold(
          appBar: AppBar(title: Text(t('settings'))),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(t('lang')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final e in const {'fa': 'فارسی', 'en': 'English', 'ar': 'العربية'}.entries) ChoiceChip(label: Text(e.value), selected: c.lang == e.key, onSelected: (_) => c.set(() => c.lang = e.key)),
            ]),
            const SizedBox(height: 22),
            Text(t('theme')),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (var i = 0; i < cols.length; i++)
                GestureDetector(
                    onTap: () => c.set(() => c.theme = i),
                    child: Container(width: 42, height: 42, decoration: BoxDecoration(color: i == 7 ? Colors.black : (i == 8 ? Colors.white : cols[i]), shape: BoxShape.circle, border: Border.all(color: Colors.grey, width: c.theme == i ? 4 : 1)))),
            ]),
            const SizedBox(height: 12),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('mode')),
                subtitle: c.proxyOnly ? const Text('SOCKS5 127.0.0.1:10808\nHTTP 127.0.0.1:10809') : null,
                value: c.proxyOnly,
                onChanged: (v) => c.set(() => c.proxyOnly = v)),
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('dev')),
                subtitle: SelectableText(c.devId),
                trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: c.devId));
                      toast(t('copied'));
                    })),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: jsonEncode({'cfgs': c.cfgs, 'subs': c.subs})));
                        toast(t('copied'));
                      },
                      child: Text(t('backup')))),
              const SizedBox(width: 10),
              Expanded(
                  child: OutlinedButton(
                      onPressed: () async {
                        try {
                          final d = await Clipboard.getData('text/plain');
                          final m = jsonDecode(d!.text!);
                          c.set(() {
                            c.cfgs = (m['cfgs'] as List).map((e) => Cfg.fromJson(e)).toList();
                            c.subs = List<String>.from(m['subs']);
                          });
                          toast(t('ok'));
                        } catch (_) {
                          toast(t('fail'));
                        }
                      },
                      child: Text(t('restore')))),
            ]),
          ])));
}
