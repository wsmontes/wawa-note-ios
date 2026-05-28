#!/bin/bash
PBXPROJ="wawa-note.xcodeproj/project.pbxproj"
if grep -q "productName = \"swift-llama\"" "$PBXPROJ"; then
    sed -i "" "s/productName = \"swift-llama\"/productName = SwiftLlama/g" "$PBXPROJ"
    echo "Fixed SwiftLlama product name in pbxproj"
fi

