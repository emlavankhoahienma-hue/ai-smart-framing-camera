from pathlib import Path

p = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera.xcodeproj/project.pbxproj'
txt = p.read_text(encoding='utf-8')

if 'UniversalSalientTargetEngine.swift' in txt:
    print("UniversalSalientTargetEngine already in pbxproj")
    exit(0)

build_entries = """\t\tD20000000000000000000071 /* UniversalSalientTargetEngine.swift in Sources */ = {isa = PBXBuildFile; fileRef = D10000000000000000000071 /* UniversalSalientTargetEngine.swift */; };
\t\tD20000000000000000000072 /* AestheticZoomPlanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = D10000000000000000000072 /* AestheticZoomPlanner.swift */; };
\t\tD20000000000000000000073 /* LocalPatchTrackingOptimizer.swift in Sources */ = {isa = PBXBuildFile; fileRef = D10000000000000000000073 /* LocalPatchTrackingOptimizer.swift */; };
\t\tD20000000000000000000074 /* CameraViewModel+UniversalTarget.swift in Sources */ = {isa = PBXBuildFile; fileRef = D10000000000000000000074 /* CameraViewModel+UniversalTarget.swift */; };
"""

file_entries = """\t\tD10000000000000000000071 /* UniversalSalientTargetEngine.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UniversalSalientTargetEngine.swift; sourceTree = "<group>"; };
\t\tD10000000000000000000072 /* AestheticZoomPlanner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AestheticZoomPlanner.swift; sourceTree = "<group>"; };
\t\tD10000000000000000000073 /* LocalPatchTrackingOptimizer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LocalPatchTrackingOptimizer.swift; sourceTree = "<group>"; };
\t\tD10000000000000000000074 /* CameraViewModel+UniversalTarget.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "CameraViewModel+UniversalTarget.swift"; sourceTree = "<group>"; };
"""

services_group_entries = """\t\t\t\tD10000000000000000000071 /* UniversalSalientTargetEngine.swift */,
\t\t\t\tD10000000000000000000072 /* AestheticZoomPlanner.swift */,
\t\t\t\tD10000000000000000000073 /* LocalPatchTrackingOptimizer.swift */,
"""

viewmodels_group_entry = """\t\t\t\tD10000000000000000000074 /* CameraViewModel+UniversalTarget.swift */,
"""

sources_build_entries = """\t\t\t\tD20000000000000000000071 /* UniversalSalientTargetEngine.swift in Sources */,
\t\t\t\tD20000000000000000000072 /* AestheticZoomPlanner.swift in Sources */,
\t\t\t\tD20000000000000000000073 /* LocalPatchTrackingOptimizer.swift in Sources */,
\t\t\t\tD20000000000000000000074 /* CameraViewModel+UniversalTarget.swift in Sources */,
"""

# 1. Insert into PBXBuildFile section
target1 = '/* Begin PBXBuildFile section */\n'
txt = txt.replace(target1, target1 + build_entries, 1)

# 2. Insert into PBXFileReference section
target2 = '/* Begin PBXFileReference section */\n'
txt = txt.replace(target2, target2 + file_entries, 1)

# 3. Insert into Services group
target3 = 'C10000000000000000000064 /* CompositionTuning.swift */,\n'
txt = txt.replace(target3, target3 + services_group_entries, 1)

# 4. Insert into ViewModels group
target4 = 'B1000000000000000000000B /* CameraViewModel.swift */,\n'
txt = txt.replace(target4, target4 + viewmodels_group_entry, 1)

# 5. Insert into PBXSourcesBuildPhase section
target5 = 'C20000000000000000000064 /* CompositionTuning.swift in Sources */,\n'
txt = txt.replace(target5, target5 + sources_build_entries, 1)

p.write_text(txt, encoding='utf-8')
print('Successfully registered 4 Universal Target & Zoom files into project.pbxproj')
