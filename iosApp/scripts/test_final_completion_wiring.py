"""Final Windows contracts. Do not label any of these as Apple runtime/device tests."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import unittest
import zlib
from unittest.mock import patch
from archive_on_mac import archive_arguments, main as archive_main
import final_completion_wiring as reviewed
ROOT = Path(__file__).resolve().parents[2]
S = "iosApp/ZTransfer/"
def read(path): return (ROOT/path).read_text(encoding="utf8")

def rgb_png(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n": raise ValueError("PNG signature")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data[16:29])
    if (width, height, depth, compression, filtering, interlace) != (1024, 1024, 8, 0, 0, 0) or color not in (2, 6):
        raise ValueError("Expected non-interlaced RGB/RGBA 1024px brand PNG")
    size = 3 if color == 2 else 4
    chunks = bytearray(); pos = 8
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos+4])[0]
        kind = data[pos+4:pos+8]; value = data[pos+8:pos+8+length]
        if kind == b"IDAT": chunks.extend(value)
        pos += length + 12
    raw = zlib.decompress(chunks)
    if len(raw) != height * (width * size + 1): raise ValueError("Pixel length")
    previous = bytearray(width * size); pixels = bytearray(); offset = 0
    def paeth(a,b,c):
        p=a+b-c; pa,pb,pc=abs(p-a),abs(p-b),abs(p-c)
        return a if pa<=pb and pa<=pc else b if pb<=pc else c
    for _ in range(height):
        method=raw[offset]; offset+=1; row=bytearray(raw[offset:offset+width*size]);offset+=width*size
        for x in range(len(row)):
            left=row[x-size] if x>=size else 0; up=previous[x]; corner=previous[x-size] if x>=size else 0
            if method==1: row[x]=(row[x]+left)&255
            elif method==2: row[x]=(row[x]+up)&255
            elif method==3: row[x]=(row[x]+((left+up)//2))&255
            elif method==4: row[x]=(row[x]+paeth(left,up,corner))&255
            elif method!=0: raise ValueError("PNG filter")
        if size==4:
            if any(row[x]!=255 for x in range(3,len(row),4)): raise ValueError("Transparent brand pixels")
            for x in range(0,len(row),4): pixels.extend(row[x:x+3])
        else: pixels.extend(row)
        previous=row
    return color, hashlib.sha256(pixels).hexdigest()

class FinalCompletionTests(unittest.TestCase):
    def test_main_ledger_scores_unique_tasks_and_keeps_mac_unverified(self):
        ledger = read("docs/技术调研/iOS剩余任务进度表.md")
        rows = re.findall(r"^\| W(\d\d) \| [^|\n]+ \| [^|\n]+ \| [^|\n]+ \| (TODO|DOING|WIN-DONE) \| ([01]) \|", ledger, re.M)
        self.assertEqual(sorted(int(row[0]) for row in rows), list(range(1, 51)))
        score = sum(int(row[2]) for row in rows)
        self.assertEqual(score, int(re.search(r"Windows 剩余任务：(\d+) / 50", ledger)[1]))
        self.assertTrue(all((state == "WIN-DONE") == (points == "1") for _, state, points in rows))
        mac = re.findall(r"^\| M(\d\d) \| [^|\n]+ \| [^|\n]+ \| ([^|\n]+) \| (\d+) \|", ledger, re.M)
        self.assertEqual(sorted(int(row[0]) for row in mac), list(range(1, 13)))
        self.assertEqual(sum(int(row[2]) for row in mac), 0)

    def test_current_handoff_links_and_all_twelve_device_scenarios_exist(self):
        paths = ["docs/技术调研/iOS剩余任务进度表.md", "docs/技术调研/iOS生命周期与恢复验收说明.md",
                 "docs/测试与验证/iOS首次Mac操作指南.md", "docs/测试与验证/iOS传图版最终交接与验收包.md"]
        for path in paths:
            for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", read(path)):
                if "://" in link or link.startswith("#"): continue
                target = link.split("#",1)[0]
                if target: self.assertTrue(((ROOT/path).parent/target).is_file(), path + ": " + link)
        handoff = read(paths[-1])
        for i in range(1,13): self.assertIn("| M%02d |" % i, handoff)
        for token in ("公开隐私政策", "SHA256", "0xFFFFFFFF", "StationProfileStore", "不自动上传"):
            self.assertIn(token, handoff)
    def test_fixed_reviewed_files_restore_and_reject_mutation(self):
        for path in reviewed.CHANGES:
            source=read(path)
            self.assertEqual(reviewed.previous_final_completion_source(path,source),
                subprocess.check_output(["git","show","f993e8e:"+path],cwd=ROOT).decode("utf8"))
            with self.assertRaises(AssertionError):
                reviewed.previous_final_completion_source(path,source+"\n// mutation\n")

    def test_no_android_host_build_manifest_or_protocol_change_after_40(self):
        paths=["app","platform","shared/src/androidMain","dist","dist-debug","gradle",
               "build.gradle.kts","settings.gradle.kts","gradle.properties","shared/build.gradle.kts"]
        self.assertEqual(subprocess.check_output(["git","diff","f993e8e","--name-only","--"]+paths,
                         cwd=ROOT).decode().strip(),"")
        changed=subprocess.check_output(["git","diff","f993e8e","--name-only","--","shared/src/commonMain"],
                                       cwd=ROOT).decode().splitlines()
        self.assertTrue(all(p.startswith("shared/src/commonMain/kotlin/com/ztransfer/ui/Native") for p in changed))

    def test_diagnostics_allowlist_single_observer_and_frozen_explicit_share(self):
        log=read(S+"Diagnostics/TransferDiagnosticLog.swift")
        for token in ("lines.count > 256","Self.models.contains", "Self.phases.contains",
                      "errors.contains(code)", "historyRevision <= history.1", "UIActivityViewController(activityItems: [request.text]"):
            self.assertIn(token,log)
        for token in ("localizedDescription", "userInfo", ".uuidString", "snapshot.rows.map", "FileManager"):
            self.assertNotIn(token,log)
        workspace=read(S+"UI/CameraWorkspace.swift")
        self.assertIn("DiagnosticShareRequest(text: diagnosticPreview)",workspace)
        self.assertIn("diagnosticPreview = report",workspace)
        probe=read(S+"Diagnostics/CameraHandshakeProbe.swift")
        self.assertEqual(probe.count("for await snapshot in queue.updates"),1)
        self.assertEqual(probe.count("diagnostics.queue(snapshot)"),1)
        for token in ("testDiagnosticRingRejectsPrivateInputs", "testDiagnosticQueueRecordsHistory"):
            self.assertIn(token,read("iosApp/ZTransferTests/CameraWorkspaceTests.swift"))

    def test_icon_is_rgb_and_pixel_identical_to_existing_brand(self):
        icon=ROOT/S/"Configuration/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        color,actual=rgb_png(icon)
        self.assertEqual(color,2)
        self.assertEqual(actual,rgb_png(ROOT/"docs/品牌素材/ztransfer_icon_1024.png")[1])
        config=json.loads(read(S+"Configuration/Assets.xcassets/AppIcon.appiconset/Contents.json"))
        self.assertEqual(config["images"][0]["filename"],"AppIcon.png")
        self.assertEqual(read("iosApp/ZTransfer.xcodeproj/project.pbxproj").count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"),2)

    def test_current_privacy_declarations_match_actual_source_scope(self):
        doc=plistlib.loads((ROOT/S/"Configuration/PrivacyInfo.xcprivacy").read_bytes())
        self.assertFalse(doc["NSPrivacyTracking"]);self.assertEqual(doc["NSPrivacyTrackingDomains"],[])
        mapping={x["NSPrivacyAccessedAPIType"]:x["NSPrivacyAccessedAPITypeReasons"] for x in doc["NSPrivacyAccessedAPITypes"]}
        self.assertEqual(mapping,{
            "NSPrivacyAccessedAPICategoryFileTimestamp":["C617.1","3B52.1"],
            "NSPrivacyAccessedAPICategoryUserDefaults":["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime":["35F9.1"]})
        self.assertIn("systemUptime",read(S+"Network/PtpIPCommandSession.swift"))
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS",read("iosApp/ZTransfer.xcodeproj/project.pbxproj"))

    def test_version_launch_and_source_contact_are_not_placeholder_actions(self):
        project=read("iosApp/ZTransfer.xcodeproj/project.pbxproj")
        app=read("app/build.gradle.kts")
        version=re.search(r'versionName = "([^"]+)"',app)[1]; code=re.search(r"versionCode = (\d+)",app)[1]
        self.assertEqual(project.count("MARKETING_VERSION = "+version+";"),2)
        self.assertEqual(project.count("CURRENT_PROJECT_VERSION = "+code+";"),2)
        self.assertEqual(project.count("INFOPLIST_KEY_UILaunchScreen_Generation = YES;"),2)
        appearance=read(S+"Configuration/AppAppearanceSettings.swift")
        self.assertIn("https://github.com/yuui226/nk_send",appearance)
        self.assertIn('UIPasteboard.general.string = "953000922"',appearance)

    def test_archive_rejects_missing_team_injection_and_escaping_output(self):
        good=ROOT/"iosApp/build/archives/test"
        for team,bundle,out in [(None,"com.ztransfer.ios",good),("bad","com.ztransfer.ios",good),
                                ("A123456789","com.example;upload",good),("A123456789","com.ztransfer.ios",ROOT)]:
            with self.assertRaises(ValueError): archive_arguments(team,bundle,out)
        args=archive_arguments("A123456789","com.ztransfer.ios",good)
        self.assertEqual(args[-1],"archive")
        self.assertNotIn("-allowProvisioningUpdates",args)
        self.assertNotIn("-exportArchive",args)

    def test_archive_default_plan_never_runs_commands_or_writes(self):
        with patch("sys.argv",["archive_on_mac.py","--team","A123456789"]), patch("builtins.print"), \
             patch("archive_on_mac.subprocess.check_output") as capture, patch("archive_on_mac.run_step") as run:
            self.assertEqual(archive_main(),0);capture.assert_not_called();run.assert_not_called()

    def test_apple_verification_is_serial_and_covers_both_configurations_and_architectures(self):
        source=read("iosApp/scripts/verify_on_mac.py")
        for stage in ("native-tests","swift-tests","release-device-build","debug-device-build","release-simulator-build"):
            self.assertIn('("'+stage+'"',source)
        self.assertIn('"-parallel-testing-enabled", "NO"',source)
        self.assertIn("for name, arguments, marker in steps:",source)

    def test_final_audit_fixes_remain_connected(self):
        ui="shared/src/commonMain/kotlin/com/ztransfer/ui/"
        self.assertIn("queue.releaseImageMemory()",read(ui+"NativeFilesPageModel.kt"))
        self.assertIn("(0...Int(Int32.max)).contains(value.completed)",read(S+"Storage/TransferRecoveryJournal.swift"))
        self.assertIn("Int32(clamping:",read(S+"UI/CameraWorkspace.swift"))
        self.assertIn('message: "@ztr|pairing"',read(S+"Diagnostics/CameraHandshakeProbe.swift"))
        self.assertIn("verticalScroll(rememberScrollState()), text = if",read(ui+"NativeProductInformation.kt"))

if __name__=="__main__": unittest.main()
