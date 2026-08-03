//  Bridging header for the visionOS app target.
//
//  The Swift immersive shell (GRApp / GRImmersiveScene) needs to reach the C
//  ABI that liblove's src/modules/xr exposes, and liblove is C++/ObjC++. Rather
//  than give Swift visibility into LÖVE's headers, everything crosses here
//  through a small hand-written C surface -- the same discipline
//  mobile/ios/patch_love_src.py follows when it reaches GRPickerBridge through
//  the ObjC runtime so liblove never links Swift.

#ifndef GEN1RECOMP_BRIDGING_HEADER_H
#define GEN1RECOMP_BRIDGING_HEADER_H

#endif /* GEN1RECOMP_BRIDGING_HEADER_H */
