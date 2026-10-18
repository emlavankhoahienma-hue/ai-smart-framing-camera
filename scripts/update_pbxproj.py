from pathlib import Path

p = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera.xcodeproj/project.pbxproj'
txt = p.read_text(encoding='utf-8')

if 'CompositionTuning.swift' in txt:
    print("Already in pbxproj")
    exit(0)

build_entries = """\t\tC20000000000000000000064 /* CompositionTuning.swift in Sources */ = {isa = PBXBuildFile; fileRef = C10000000000000000000064 /* CompositionTuning.swift */; };
\t\tC20000000000000000000065 /* CompositionPureCalculations.swift in Sources */ = {isa = PBXBuildFile; fileRef = C10000000000000000000065 /* CompositionPureCalculations.swift */; };
\t\tC20000000000000000000066 /* CompositionExperiments.swift in Sources */ = {isa = PBXBuildFile; fileRef = C10000000000000000000066 /* CompositionExperiments.swift */; };
\t\tC20000000000000000000067 /* CompositionDebugOverlayView.swift in Sources */ = {isa = PBXBuildFile; fileRef = C10000000000000000000067 /* CompositionDebugOverlayView.swift */; };
"""

file_entries = """\t\tC10000000000000000000064 /* CompositionTuning.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CompositionTuning.swift; sourceTree = "<group>"; };
\t\tC10000000000000000000065 /* CompositionPureCalculations.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CompositionPureCalculations.swift; sourceTree = "<group>"; };
\t\tC10000000000000000000066 /* CompositionExperiments.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CompositionExperiments.swift; sourceTree = "<group>"; };
\t\tC10000000000000000000067 /* CompositionDebugOverlayView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CompositionDebugOverlayView.swift; sourceTree = "<group>"; };
"""

services_group_entries = """\t\t\t\tC10000000000000000000064 /* CompositionTuning.swift */,
\t\t\t\tC10000000000000000000065 /* CompositionPureCalculations.swift */,
\t\t\t\tC10000000000000000000066 /* CompositionExperiments.swift */,
"""

views_group_entry = """\t\t\t\tC10000000000000000000067 /* CompositionDebugOverlayView.swift */,
"""

sources_build_entries = """\t\t\t\tC20000000000000000000064 /* CompositionTuning.swift in Sources */,
\t\t\t\tC20000000000000000000065 /* CompositionPureCalculations.swift in Sources */,
\t\t\t\tC20000000000000000000066 /* CompositionExperiments.swift in Sources */,
\t\t\t\tC20000000000000000000067 /* CompositionDebugOverlayView.swift in Sources */,
"""

# 1. Insert into PBXBuildFile section
target1 = '/* Begin PBXBuildFile section */\n'
txt = txt.replace(target1, target1 + build_entries, 1)

# 2. Insert into PBXFileReference section
target2 = '/* Begin PBXFileReference section */\n'
txt = txt.replace(target2, target2 + file_entries, 1)

# 3. Insert into Services group
target3 = 'C10000000000000000000063 /* PortraitFramingEvidence.swift */,\n'
txt = txt.replace(target3, target3 + services_group_entries, 1)

# 4. Insert into Views group
target4 = 'B1000000000000000000000C /* ARFramingOverlayView.swift */,\n'
txt = txt.replace(target4, target4 + views_group_entry, 1)

# 5. Insert into PBXSourcesBuildPhase section
target5 = 'C20000000000000000000063 /* PortraitFramingEvidence.swift in Sources */,\n'
txt = txt.replace(target5, target5 + sources_build_entries, 1)

p.write_text(txt, encoding='utf-8')
print('Successfully registered 4 files into project.pbxproj')
