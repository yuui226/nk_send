import subprocess,sys
round = sys.argv[1]
root='/tmp/ztransfer-preview-layout'
build=['xcodebuild','build-for-testing','-project','ios/ZTransfer.xcodeproj','-scheme','ZTransfer','-configuration','Debug','-destination','generic/platform=iOS Simulator','-derivedDataPath','/tmp/ztransfer-removal-derived-20261021','CODE_SIGN_IDENTITY=-']
with open(root+'-build-20261031-r'+round+'.log','w') as log:r=subprocess.run(build,stdout=log,stderr=subprocess.STDOUT)
print('BUILD',r.returncode,flush=True)
if r.returncode:raise SystemExit(r.returncode)
test=['xcodebuild','test-without-building','-xctestrun','/tmp/ztransfer-removal-derived-20261021/Build/Products/ZTransfer_preview_trace.xctestrun','-destination','platform=iOS Simulator,id=CA046456-B859-45F4-9CB3-2C6E2F8E03B0','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-default-test-execution-time-allowance','60','-maximum-test-execution-time-allowance','120','-resultBundlePath',root+'-20261031-r'+round+'.xcresult']
classes=['PhotoPreviewOpeningRenderingTests','PhotoPreviewCropRenderingTests','PhotoPreviewAnchorGeometryTests','PhotoPreviewReturnScrollTests','PhotoPreviewEffectsTests']
test += ['-only-testing:ZTransferTests/'+c for c in classes]
with open(root+'-20261031-r'+round+'.log','w') as log:r=subprocess.run(test,stdout=log,stderr=subprocess.STDOUT)
print('TEST',r.returncode,flush=True)
raise SystemExit(r.returncode)
