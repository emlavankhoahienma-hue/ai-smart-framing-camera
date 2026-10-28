from pathlib import Path

p = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera.xcodeproj/project.pbxproj'
txt = p.read_text(encoding='utf-8')

needle = 'D10000000000000000000074 /* CameraViewModel+UniversalTarget.swift */,'
if needle in txt:
    print("Already in children!")
else:
    target = 'B10000000000000000000009 /* CameraViewModel.swift */,\n'
    replacement = target + '\t\t\t\tD10000000000000000000074 /* CameraViewModel+UniversalTarget.swift */,\n'
    if target in txt:
        txt = txt.replace(target, replacement, 1)
        p.write_text(txt, encoding='utf-8')
        print("Successfully added CameraViewModel+UniversalTarget.swift into ViewModels group!")
    else:
        print("Target B10000000000000000000009 not found!")
