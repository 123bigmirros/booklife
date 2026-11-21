#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; all app code remains in normal folders."""
import hashlib
import pathlib
import plistlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
objects = {}


def add(key, **fields):
    ident = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    objects[ident] = fields
    return ident


def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + serialize(k) + " = " + serialize(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(v, level) for v in value) + ")"
    value = str(value)
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def configs(name, settings):
    ids = []
    for mode in ["Debug", "Release"]:
        values = dict(settings, SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O")
        if mode == "Debug":
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            values["ENABLE_TESTABILITY"] = "YES"
        ids.append(add(name + mode, isa="XCBuildConfiguration", name=mode, buildSettings=values))
    return add(name + "configs", isa="XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")


# Cloud-sync conflict copies are never build inputs; local history lives in build/.
sources = sorted(str(p.relative_to(ROOT)) for folder in ["Sources", "Apps"] for p in (ROOT / folder).rglob("*.swift") if not any(".sync-conflict-" in part for part in p.relative_to(ROOT).parts))
refs = {p: add(p, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", name=pathlib.Path(p).name, path=p, sourceTree="SOURCE_ROOT") for p in sources}
products = []
targets = []
target_ids = {}
product_ids = {}
for name, platform in [("BookSlideMac", "mac"), ("BookSlideWatch", "watch"), ("BookSlidePhone", "phone")]:
    watch = platform == "watch"
    phone = platform == "phone"
    if watch or phone:
        paths = [p for p in sources if p.startswith(("Apps/watchOS/" if watch else "Apps/iOS/", "Apps/Shared/", "Sources/BookSlideCore/"))]
    else:
        paths = [p for p in sources if p.startswith(("Sources/BookSlideMac/", "Sources/BookSlideCore/", "Sources/BookSlideTransport/", "Sources/BookSlideTerminal/"))]
    if phone:
        paths += ["Sources/BookSlideMac/Reader/BookReadingTools.swift", "Sources/BookSlideMac/Reader/ReadingInterface.swift", "Sources/BookSlideMac/Notes/LibraryNotes.swift", "Sources/BookSlideMac/Notes/NoteMarkdownExport.swift", "Sources/BookSlideMac/Notes/ReaderDiscussionViews.swift"]
        paths += ["Sources/BookSlideMac/Notes/BookNotesWorkspace.swift", "Sources/BookSlideMac/Notes/BookGraphInspectors.swift", "Sources/BookSlideMac/Notes/ReaderKnowledge.swift", "Sources/BookSlideMac/Notes/MindMapDocument.swift", "Sources/BookSlideMac/Notes/ReaderNoteRecovery.swift", "Sources/BookSlideMac/Reader/ReaderModel.swift", "Sources/BookSlideMac/Reader/PDFBookReader.swift", "Sources/BookSlideMac/Reader/PDFPageLayers.swift", "Sources/BookSlideMac/Reader/PDFReflowCanvas.swift", "Sources/BookSlideMac/Reader/PDFScanText.swift", "Sources/BookSlideMac/Notes/ReaderAnnotations.swift", "Sources/BookSlideMac/Notes/ReaderPageNotes.swift", "Sources/BookSlideMac/Notes/ReaderPageNoteSchemeHandler.swift", "Sources/BookSlideMac/Reader/ReadingComponents.swift", "Sources/BookSlideMac/Notes/BookStructureView.swift", "Sources/BookSlideMac/Reader/PageTurnSheet.swift", "Sources/BookSlideMac/Sync/ReaderProgress.swift", "Sources/BookSlideMac/Sync/ProgressSyncView.swift", "Sources/BookSlideTransport/HTTPServer.swift", "Sources/BookSlideTransport/BluetoothReceiver.swift"]
    files = [add(name + p, isa="PBXBuildFile", fileRef=refs[p]) for p in paths]
    phase = add(name + "sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)
    frameworks = add(name + "frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    resources = add(name + "resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    if platform == "mac" or phone:
        reader_ref = add("reader-resources", isa="PBXFileReference", lastKnownFileType="folder", path="Sources/BookSlideMac/Resources/Reader", sourceTree="SOURCE_ROOT")
        refs["Sources/BookSlideMac/Resources/Reader"] = reader_ref
        objects[resources]["files"] = [add(name + "reader-resource-build", isa="PBXBuildFile", fileRef=reader_ref)]
    if phone:
        assets_ref = add("phone-assets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets/Phone.xcassets", sourceTree="SOURCE_ROOT")
        refs["Assets/Phone.xcassets"] = assets_ref
        objects[resources]["files"].append(add(name + "assets-build", isa="PBXBuildFile", fileRef=assets_ref))
    app_name = "booklife" if platform == "mac" else name.replace("BookSlide", "booklife", 1)
    product = add(name + "product", isa="PBXFileReference", explicitFileType="wrapper.application", path=app_name + ".app", sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
    products.append(product)
    product_ids[name] = product
    settings = {
        "PRODUCT_NAME": app_name, "PRODUCT_MODULE_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": "dev.bookslide" if phone else "dev.bookslide." + platform,
        "SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "66",
        "MARKETING_VERSION": "0.5.0", "INFOPLIST_FILE": "Config/" + name + "-Info.plist",
        "SDKROOT": "watchos" if watch else ("iphoneos" if phone else "macosx"), "GENERATE_INFOPLIST_FILE": "NO",
        "ENABLE_APP_SANDBOX": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
    }
    if watch:
        settings.update(WATCHOS_DEPLOYMENT_TARGET="10.0", TARGETED_DEVICE_FAMILY="4", SUPPORTED_PLATFORMS="watchos watchsimulator", SKIP_INSTALL="NO")
    elif phone:
        settings.update(IPHONEOS_DEPLOYMENT_TARGET="17.0", TARGETED_DEVICE_FAMILY="1,2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator")
        settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    else:
        settings.update(MACOSX_DEPLOYMENT_TARGET="13.0", SUPPORTED_PLATFORMS="macosx", COMBINE_HIDPI_IMAGES="YES")
    target = add(name + "target", isa="PBXNativeTarget", buildConfigurationList=configs(name, settings), buildPhases=[phase, frameworks, resources], buildRules=[], dependencies=[], name=name, productName=app_name, productReference=product, productType="com.apple.product-type.application")
    target_ids[name] = target
    if phone:
        watch_target = target_ids["BookSlideWatch"]
        project_id = hashlib.sha256(b"project").hexdigest()[:24].upper()
        proxy = add("watch-proxy", isa="PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=watch_target, remoteInfo="BookSlideWatch")
        dependency = add("phone-watch-dependency", isa="PBXTargetDependency", target=watch_target, targetProxy=proxy)
        embed_file = add("embed-watch-file", isa="PBXBuildFile", fileRef=product_ids["BookSlideWatch"], settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
        embed_phase = add("embed-watch-phase", isa="PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embed_file], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0)
        objects[target]["dependencies"] = [dependency]
        objects[target]["buildPhases"].append(embed_phase)
    targets.append(target)
    info = {
        "CFBundleDevelopmentRegion": "zh_CN", "CFBundleDisplayName": "书籍人生",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSLocalNetworkUsageDescription": "连接同一局域网中的阅读器，同步书籍、进度和遥控状态。",
    }
    if watch or phone or platform == "mac":
        info["NSBluetoothAlwaysUsageDescription"] = "通过蓝牙让 Apple Watch 直接连接 Mac 或 iPad，控制滚动与翻页，无需手机中转。"
    if watch:
        info.update(WKApplication=True, WKCompanionAppBundleIdentifier="dev.bookslide", WKRunsIndependentlyOfCompanionApp=True, WKSupportsAlwaysOnDisplay=True, UIBackgroundModes=["bluetooth-central"],
                    NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
    elif phone:
        info.update(UILaunchScreen={}, LSRequiresIPhoneOS=True,
                    LSSupportsOpeningDocumentsInPlace=True,
                    CFBundleDocumentTypes=[{"CFBundleTypeName":"EPUB", "CFBundleTypeRole":"Viewer", "LSHandlerRank":"Alternate", "LSItemContentTypes":["org.idpf.epub-container"]}],
                    UTImportedTypeDeclarations=[{"UTTypeIdentifier":"org.idpf.epub-container", "UTTypeConformsTo":["public.data"], "UTTypeDescription":"EPUB", "UTTypeTagSpecification":{"public.filename-extension":["epub"],"public.mime-type":"application/epub+zip"}}],
                    UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                    **{"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]},
                    NSBonjourServices=["_bookslide._tcp"],
                    NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
    else:
        info.update(LSMinimumSystemVersion="$(MACOSX_DEPLOYMENT_TARGET)", NSPrincipalClass="NSApplication", NSHighResolutionCapable=True,
                    NSBonjourServices=["_bookslide._tcp"],
                    CFBundleDocumentTypes=[{"CFBundleTypeName":"EPUB Book", "CFBundleTypeRole":"Viewer", "LSHandlerRank":"Alternate", "LSItemContentTypes":["org.idpf.epub-container"]}],
                    UTImportedTypeDeclarations=[{"UTTypeIdentifier":"org.idpf.epub-container", "UTTypeConformsTo":["public.data"], "UTTypeDescription":"EPUB Book", "UTTypeTagSpecification":{"public.filename-extension":["epub"],"public.mime-type":"application/epub+zip"}}])
    if platform == "mac" or phone:
        info["CFBundleDocumentTypes"].append({
            "CFBundleTypeName": "PDF",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["com.adobe.pdf"],
        })
        info.setdefault("UTImportedTypeDeclarations", []).append({
            "UTTypeIdentifier": "net.daringfireball.markdown",
            "UTTypeConformsTo": ["public.plain-text"],
            "UTTypeDescription": "Markdown",
            "UTTypeTagSpecification": {"public.filename-extension": ["md", "markdown"], "public.mime-type": "text/markdown"},
        })
    (ROOT / "Config" / (name + "-Info.plist")).write_bytes(plistlib.dumps(info))
    info_path = "Config/" + name + "-Info.plist"
    refs[info_path] = add(info_path, isa="PBXFileReference", lastKnownFileType="text.plist.xml", name=pathlib.Path(info_path).name, path=info_path, sourceTree="SOURCE_ROOT")
    scheme_dir = ROOT / "booklife.xcodeproj/xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    build_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{app_name}.app" BlueprintName="{name}" ReferencedContainer="container:booklife.xcodeproj"/>'
    (scheme_dir / (name.replace("BookSlide", "booklife", 1) + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{build_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

# iPad-hosted PencilKit tests run against the real production canvas and store.
test_name = "BookSlidePencilTests"
test_paths = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Tests/BookSlidePencilTests").glob("*.swift"))
for test_path in test_paths:
    refs[test_path] = add(test_path, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", name=pathlib.Path(test_path).name, path=test_path, sourceTree="SOURCE_ROOT")
test_sources = add(test_name + "sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[add(test_name + p, isa="PBXBuildFile", fileRef=refs[p]) for p in test_paths], runOnlyForDeploymentPostprocessing=0)
test_frameworks = add(test_name + "frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
test_product = add(test_name + "product", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path=test_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
products.append(test_product)
test_proxy = add(test_name + "proxy", isa="PBXContainerItemProxy", containerPortal=hashlib.sha256(b"project").hexdigest()[:24].upper(), proxyType=1, remoteGlobalIDString=target_ids["BookSlidePhone"], remoteInfo="BookSlidePhone")
test_dependency = add(test_name + "dependency", isa="PBXTargetDependency", target=target_ids["BookSlidePhone"], targetProxy=test_proxy)
test_settings = {"PRODUCT_NAME":"$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER":"dev.bookslide.pencil-tests", "SWIFT_VERSION":"5.0", "GENERATE_INFOPLIST_FILE":"YES", "SDKROOT":"iphoneos", "IPHONEOS_DEPLOYMENT_TARGET":"17.0", "TARGETED_DEVICE_FAMILY":"1,2", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "TEST_TARGET_NAME":"BookSlidePhone", "TEST_HOST":"$(BUILT_PRODUCTS_DIR)/booklifePhone.app/booklifePhone", "BUNDLE_LOADER":"$(TEST_HOST)"}
test_target = add(test_name + "target", isa="PBXNativeTarget", buildConfigurationList=configs(test_name,test_settings), buildPhases=[test_sources,test_frameworks], buildRules=[], dependencies=[test_dependency], name=test_name, productName=test_name, productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
targets.append(test_target)
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="{test_name}.xctest" BlueprintName="{test_name}" ReferencedContainer="container:booklife.xcodeproj"/>'
(ROOT / "booklife.xcodeproj/xcshareddata/xcschemes" / (test_name.replace("BookSlide", "booklife", 1) + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{test_ref}</TestableReference></Testables></TestAction>
</Scheme>
''')

# End-to-end iPad tests operate through the shipped library and reading UI.
ui_name = "BookSlideUITests"
ui_paths = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Tests/BookSlideUITests").glob("*.swift"))
for path in ui_paths:
    refs[path] = add(path, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", name=pathlib.Path(path).name, path=path, sourceTree="SOURCE_ROOT")
ui_sources = add(ui_name + "sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[add(ui_name + p, isa="PBXBuildFile", fileRef=refs[p]) for p in ui_paths], runOnlyForDeploymentPostprocessing=0)
ui_frameworks = add(ui_name + "frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
ui_product = add(ui_name + "product", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path=ui_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
products.append(ui_product)
ui_settings = {"PRODUCT_NAME":"$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER":"dev.bookslide.ui-tests", "SWIFT_VERSION":"5.0", "GENERATE_INFOPLIST_FILE":"YES", "SDKROOT":"iphoneos", "IPHONEOS_DEPLOYMENT_TARGET":"17.0", "TARGETED_DEVICE_FAMILY":"1,2", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "TEST_TARGET_NAME":"BookSlidePhone"}
ui_target = add(ui_name + "target", isa="PBXNativeTarget", buildConfigurationList=configs(ui_name,ui_settings), buildPhases=[ui_sources,ui_frameworks], buildRules=[], dependencies=[test_dependency], name=ui_name, productName=ui_name, productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
targets.append(ui_target)
ui_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="{ui_name}.xctest" BlueprintName="{ui_name}" ReferencedContainer="container:booklife.xcodeproj"/>'
(ROOT / "booklife.xcodeproj/xcshareddata/xcschemes" / (ui_name.replace("BookSlide", "booklife", 1) + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ui_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{ui_ref}</TestableReference></Testables></TestAction>
</Scheme>
''')

products_group = add("products", isa="PBXGroup", children=products, name="Products", sourceTree="<group>")


def source_group(folder=""):
    """Mirror on-disk folders in Xcode instead of a flat list of full paths."""
    children = []
    subfolders = set()
    for path, ref in sorted(refs.items()):
        if folder and not path.startswith(folder + "/"):
            continue
        relative = pathlib.PurePosixPath(path).relative_to(folder) if folder else pathlib.PurePosixPath(path)
        if len(relative.parts) == 1:
            objects[ref]["name"] = relative.name
            children.append(ref)
        else:
            subfolders.add(relative.parts[0])
    groups = []
    for name in sorted(subfolders):
        subfolder = str(pathlib.PurePosixPath(folder) / name)
        groups.append(source_group(subfolder))
    return add("source-group:" + folder, isa="PBXGroup", children=groups + children,
               name=pathlib.PurePosixPath(folder).name, sourceTree="<group>")


main = source_group()
objects[main]["children"].append(products_group)
project = add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2700"}, buildConfigurationList=configs("project", {"CLANG_ENABLE_MODULES": "YES"}), compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN", hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"], mainGroup=main, productRefGroup=products_group, projectDirPath="", projectRoot="", targets=targets)
document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
(ROOT / "booklife.xcodeproj/project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(document) + "\n")
print("Generated booklife.xcodeproj")
