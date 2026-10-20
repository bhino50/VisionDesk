#!/usr/bin/env python3
"""Generate the visionOS app and shared frameworks using the standard library."""

from hashlib import sha256
import os
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "VisionDesk.xcodeproj"
OBJECTS = {}
BUNDLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
TEAM_ID_PATTERN = re.compile(r"^[A-Za-z0-9]{10}$")
DEFAULT_BUNDLE_ID = "org.visiondesk.VisionDesk"
# The app target references these at build time, so a missing one yields a project that only
# fails once Xcode runs. All required resources are checked before anything is written.
ICON_CATALOG = "VisionApp/Assets.xcassets"
ICON_STACK = ICON_CATALOG + "/AppIcon.solidimagestack"
REQUIRED_RESOURCES = (
    "VisionApp/Info.plist", "VisionApp/VisionDesk.entitlements",
    ICON_CATALOG + "/Contents.json",
    ICON_STACK + "/Contents.json",
    ICON_STACK + "/Front.solidimagestacklayer/Contents.json",
    ICON_STACK + "/Front.solidimagestacklayer/Content.imageset/Contents.json",
    ICON_STACK + "/Front.solidimagestacklayer/Content.imageset/foreground.png",
    ICON_STACK + "/Back.solidimagestacklayer/Contents.json",
    ICON_STACK + "/Back.solidimagestacklayer/Content.imageset/Contents.json",
    ICON_STACK + "/Back.solidimagestacklayer/Content.imageset/background.png",
)


def project_identifier(name, pattern, guidance, default=None):
    """Validated environment identifier, or `default` when the variable is unset.

    Every write in this script happens at the end, so raising here leaves an already
    registered project untouched. A set-but-blank value is a malformed override rather than
    an absent one: silently substituting the example identifier is how a device build ended
    up shipping `com.example.VisionDesk`.
    """
    raw = os.environ.get(name)
    if raw is None:
        return "" if default is None else default
    value = raw.strip()
    if not pattern.match(value):
        raise SystemExit(
            f"{name} must be {guidance}. VisionDesk.xcodeproj was left unchanged."
        )
    return value


TEAM = project_identifier(
    "VISION_DESK_TEAM_ID", TEAM_ID_PATTERN,
    "a ten-character Apple development team identifier",
)
BUNDLE_ID = project_identifier(
    "VISION_DESK_BUNDLE_ID", BUNDLE_ID_PATTERN,
    "a reverse-DNS app identifier such as com.example.VisionDesk", DEFAULT_BUNDLE_ID,
)
for resource in REQUIRED_RESOURCES:
    if not (ROOT / resource).is_file():
        raise SystemExit(
            f"Missing required app resource: {resource}. "
            "VisionDesk.xcodeproj was left unchanged."
        )


def identifier(name):
    return sha256(name.encode("utf-8")).hexdigest()[:24].upper()


def obj(key, isa, **values):
    reference = identifier(key)
    assert reference not in OBJECTS, f"Duplicate project object key: {key}"
    OBJECTS[reference] = {"isa": isa, **values}
    return reference


def configuration_list(key, configurations):
    return obj(
        key, "XCConfigurationList", buildConfigurations=configurations,
        defaultConfigurationIsVisible=0, defaultConfigurationName="Debug",
    )


def source_group(name, directory):
    references, builds = [], []
    for path in sorted((ROOT / directory).rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        reference = obj(
            relative, "PBXFileReference", lastKnownFileType="sourcecode.swift",
            path=relative, sourceTree="<group>",
        )
        references.append(reference)
        builds.append(obj(relative + "-build", "PBXBuildFile", fileRef=reference))
    group = obj(name + "-group", "PBXGroup", name=name, children=references, sourceTree="<group>")
    phase = obj(
        name + "-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
        files=builds, runOnlyForDeploymentPostprocessing=0,
    )
    return group, phase


def target_configs(name, app=False, test=False):
    common = {
        "CLANG_ENABLE_MODULES": "YES",
        "SDKROOT": "xros",
        "SUPPORTED_PLATFORMS": "xros xrsimulator",
        "SWIFT_VERSION": "5.0",
        "XROS_DEPLOYMENT_TARGET": "2.0",
        "TARGETED_DEVICE_FAMILY": "7",
        "PRODUCT_NAME": name,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID if app else BUNDLE_ID + "." + name,
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": TEAM,
        "CURRENT_PROJECT_VERSION": "7",
        "MARKETING_VERSION": "0.4.2",
        "GENERATE_INFOPLIST_FILE": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if test:
        # A hosted unit-test bundle loads into the app, so it reuses the frameworks the app
        # already embeds instead of carrying its own copies.
        common.update({
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/VisionDesk.app/VisionDesk",
            "BUNDLE_LOADER": "$(TEST_HOST)",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        })
    elif app:
        common.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "INFOPLIST_FILE": "VisionApp/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "VisionApp/VisionDesk.entitlements",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        })
    else:
        common.update({
            "DEFINES_MODULE": "YES",
            "SKIP_INSTALL": "YES",
            "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks",
            "DYLIB_INSTALL_NAME_BASE": "@rpath",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        })
    configs = []
    for mode in ("Debug", "Release"):
        settings = dict(common)
        settings.update({
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
        })
        if mode == "Debug":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ["$(inherited)", "DEBUG"]
            # `@testable import VisionDesk` and `@testable import DeskTransport` need the app
            # and framework modules compiled with testability. Release stays unchanged.
            settings["ENABLE_TESTABILITY"] = "YES"
        configs.append(obj(name + "-" + mode, "XCBuildConfiguration", name=mode, buildSettings=settings))
    return configuration_list(name + "-configs", configs)


groups, targets, products, target_ids, product_ids = [], [], [], {}, {}
for name in ("DeskCore", "DeskTransport", "VisionDesk"):
    target_ids[name] = identifier(name + "-target")
    is_app = name == "VisionDesk"
    product_ids[name] = obj(
        name + "-product", "PBXFileReference",
        explicitFileType="wrapper.application" if is_app else "wrapper.framework",
        path=name + (".app" if is_app else ".framework"), sourceTree="BUILT_PRODUCTS_DIR",
    )
    products.append(product_ids[name])

for name in ("DeskCore", "DeskTransport", "VisionDesk"):
    is_app = name == "VisionDesk"
    directory = "VisionApp" if is_app else "Sources/" + name
    if not (ROOT / directory).is_dir():
        raise SystemExit(
            f"Missing source directory: {directory}. "
            "VisionDesk.xcodeproj was left unchanged."
        )
    group, sources = source_group(name, directory)
    groups.append(group)
    linked_names = [] if name == "DeskCore" else (["DeskCore"] if name == "DeskTransport" else ["DeskCore", "DeskTransport"])
    dependencies, framework_builds, embed_builds = [], [], []
    for linked in linked_names:
        proxy = obj(
            name + "-" + linked + "-proxy", "PBXContainerItemProxy",
            containerPortal=identifier("project"), proxyType=1,
            remoteGlobalIDString=target_ids[linked], remoteInfo=linked,
        )
        dependencies.append(obj(
            name + "-" + linked + "-dependency", "PBXTargetDependency",
            target=target_ids[linked], targetProxy=proxy,
        ))
        framework_builds.append(obj(
            name + "-" + linked + "-link", "PBXBuildFile", fileRef=product_ids[linked],
        ))
        if is_app:
            embed_builds.append(obj(
                name + "-" + linked + "-embed", "PBXBuildFile", fileRef=product_ids[linked],
                settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]},
            ))
    frameworks = obj(
        name + "-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
        files=framework_builds, runOnlyForDeploymentPostprocessing=0,
    )
    phases = [sources, frameworks]
    if is_app:
        catalog = obj(
            "app-assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog",
            path=ICON_CATALOG, sourceTree="<group>",
        )
        OBJECTS[group]["children"].append(catalog)
        catalog_build = obj("app-assets-build", "PBXBuildFile", fileRef=catalog)
        phases.append(obj(
            name + "-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
            files=[catalog_build], runOnlyForDeploymentPostprocessing=0,
        ))
        phases.append(obj(
            name + "-embed-frameworks", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
            dstPath="", dstSubfolderSpec=10, files=embed_builds,
            name="Embed Frameworks", runOnlyForDeploymentPostprocessing=0,
        ))
    targets.append(obj(
        name + "-target", "PBXNativeTarget", buildConfigurationList=target_configs(name, is_app),
        buildPhases=phases, buildRules=[], dependencies=dependencies,
        name=name, productName=name, productReference=product_ids[name],
        productType="com.apple.product-type.application" if is_app else "com.apple.product-type.framework",
    ))

# Hosted XCTest bundle for the visionOS client. It runs inside the app, so it can reach the
# app's own modules with `@testable import` instead of duplicating client sources.
TEST_NAME = "VisionTests"
if not (ROOT / TEST_NAME).is_dir():
    raise SystemExit(
        f"Missing source directory: {TEST_NAME}. "
        "VisionDesk.xcodeproj was left unchanged."
    )
test_target_id = identifier(TEST_NAME + "-target")
test_product = obj(
    TEST_NAME + "-product", "PBXFileReference", explicitFileType="wrapper.cfbundle",
    path=TEST_NAME + ".xctest", sourceTree="BUILT_PRODUCTS_DIR",
)
products.append(test_product)
test_group, test_sources = source_group(TEST_NAME, TEST_NAME)
groups.append(test_group)
test_dependencies, test_links = [], []
for linked in ("DeskCore", "DeskTransport", "VisionDesk"):
    proxy = obj(
        TEST_NAME + "-" + linked + "-proxy", "PBXContainerItemProxy",
        containerPortal=identifier("project"), proxyType=1,
        remoteGlobalIDString=target_ids[linked], remoteInfo=linked,
    )
    test_dependencies.append(obj(
        TEST_NAME + "-" + linked + "-dependency", "PBXTargetDependency",
        target=target_ids[linked], targetProxy=proxy,
    ))
    # The host app supplies the loaded frameworks at run time; the bundle links them at build
    # time for `@testable import DeskTransport`. It never embeds a second copy.
    if linked != "VisionDesk":
        test_links.append(obj(
            TEST_NAME + "-" + linked + "-link", "PBXBuildFile", fileRef=product_ids[linked],
        ))
targets.append(obj(
    TEST_NAME + "-target", "PBXNativeTarget",
    buildConfigurationList=target_configs(TEST_NAME, test=True),
    buildPhases=[
        test_sources,
        obj(
            TEST_NAME + "-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
            files=test_links, runOnlyForDeploymentPostprocessing=0,
        ),
    ],
    buildRules=[], dependencies=test_dependencies, name=TEST_NAME, productName=TEST_NAME,
    productReference=test_product, productType="com.apple.product-type.bundle.unit-test",
))

product_group = obj("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
main_group = obj("main", "PBXGroup", children=groups + [product_group], sourceTree="<group>")
project_configs = [
    obj(
        "project-" + mode, "XCBuildConfiguration", name=mode,
        buildSettings={"SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES"},
    )
    for mode in ("Debug", "Release")
]
target_attributes = {
    target: {"CreatedOnToolsVersion": "27.0", "ProvisioningStyle": "Automatic"} for target in targets
}
target_attributes[test_target_id]["TestTargetID"] = target_ids["VisionDesk"]
root = obj(
    "project", "PBXProject",
    attributes={"LastUpgradeCheck": "2700", "TargetAttributes": target_attributes},
    buildConfigurationList=configuration_list("project-configs", project_configs),
    compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
    knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=product_group,
    projectDirPath="", projectRoot="", targets=targets,
)

PROJECT.mkdir(exist_ok=True)
with (PROJECT / "project.pbxproj").open("wb") as output:
    plistlib.dump(
        {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": OBJECTS, "rootObject": root},
        output, sort_keys=False,
    )

schemes = PROJECT / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)


def buildable_reference(blueprint, name, product):
    return (
        '<BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{blueprint}" BuildableName="{product}" '
        f'BlueprintName="{name}" ReferencedContainer="container:VisionDesk.xcodeproj"/>'
    )


buildable = buildable_reference(target_ids["VisionDesk"], "VisionDesk", "VisionDesk.app")
test_buildable = buildable_reference(test_target_id, TEST_NAME, TEST_NAME + ".xctest")
(schemes / "VisionDesk.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO">{test_buildable}</TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
print(PROJECT)
