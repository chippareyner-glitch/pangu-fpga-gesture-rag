#!/usr/bin/env python3
"""
dataset_collector_webcam.py
---------------------------
Real-time USB Webcam Gesture Collector and 32x32 Dual-Channel Dataset Builder.
Features:
- YCrCb Skin Detection & Morphological Cleanup.
- Largest Contour Extent Tracking & 32x32 ROI Normalization.
- Frame Difference Channel Generation (Channel 1: Mask, Channel 2: XOR Difference).
- One-key labeling and saving to .npy / PNG batches for hardware training.
"""

import os
import cv2
import numpy as np

def run_collector(output_dir="gesture_dataset"):
    os.makedirs(output_dir, exist_ok=True)
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("[!] Error: Could not open camera device 0.")
        return

    print("=" * 60)
    print("  FPGA 32x32 Dual-Channel Gesture Dataset Collector")
    print("=" * 60)
    print("  Keys:")
    print("    '0': Save sample as Class 0 (Hover / Pointer)")
    print("    '1': Save sample as Class 1 (Thumb-Click)")
    print("    '2': Save sample as Class 2 (Fist / Grab)")
    print("    '3': Save sample as Class 3 (Open Palm)")
    print("    'q': Exit collector")
    print("=" * 60)

    prev_roi_binary = np.zeros((32, 32), dtype=np.uint8)
    sample_counts = {0: 0, 1: 0, 2: 0, 3: 0}

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame = cv2.flip(frame, 1) # Mirror display
        h, w, _ = frame.shape

        # 1. Skin Color Thresholding in YCrCb
        ycrcb = cv2.cvtColor(frame, cv2.COLOR_BGR2YCrCb)
        # Skin range: Cb: 77-127, Cr: 133-173
        lower_skin = np.array([0, 133, 77], dtype=np.uint8)
        upper_skin = np.array([255, 173, 127], dtype=np.uint8)
        mask = cv2.inRange(ycrcb, lower_skin, upper_skin)

        # 2. Morphological Cleanup
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
        mask = cv2.morphologyEx(mask, cv2.MORPH_DILATE, kernel, iterations=2)

        # 3. Find Largest Hand Contour
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        roi_32 = np.zeros((32, 32), dtype=np.uint8)
        diff_32 = np.zeros((32, 32), dtype=np.uint8)

        if contours:
            largest = max(contours, key=cv2.contourArea)
            if cv2.contourArea(largest) > 1000:
                x, y, bw, bh = cv2.boundingRect(largest)
                cv2.rectangle(frame, (x, y), (x + bw, y + bh), (0, 255, 0), 2)
                
                # Extract and resize to 32x32
                hand_crop = mask[y:y+bh, x:x+bw]
                roi_32 = cv2.resize(hand_crop, (32, 32), interpolation=cv2.INTER_NEAREST)
                roi_32 = (roi_32 > 128).astype(np.uint8) * 255

                # 4-frame / step XOR difference
                diff_32 = cv2.bitwise_xor(roi_32, prev_roi_binary)
                prev_roi_binary = roi_32.copy()

        # Visualization
        disp_roi = cv2.resize(roi_32, (128, 128), interpolation=cv2.INTER_NEAREST)
        disp_diff = cv2.resize(diff_32, (128, 128), interpolation=cv2.INTER_NEAREST)
        
        cv2.putText(disp_roi, "Ch0: Mask", (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)
        cv2.putText(disp_diff, "Ch1: XOR Diff", (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)
        
        cv2.imshow("Original Feed (Mirror)", frame)
        cv2.imshow("Hardware Dual Channels (32x32)", np.hstack([disp_roi, disp_diff]))

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key in [ord('0'), ord('1'), ord('2'), ord('3')]:
            cls_id = int(chr(key))
            sample_counts[cls_id] += 1
            # Stack dual channel into (2, 32, 32)
            sample_data = np.stack([(roi_32 > 0).astype(np.float32), (diff_32 > 0).astype(np.float32)], axis=0)
            fname = os.path.join(output_dir, f"sample_c{cls_id}_{sample_counts[cls_id]:04d}.npy")
            np.save(fname, sample_data)
            print(f"[+] Saved sample for Class {cls_id} -> {fname} (Total: {sample_counts[cls_id]})")

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    run_collector()
