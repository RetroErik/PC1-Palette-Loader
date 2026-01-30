#!/usr/bin/env python3
"""
mkpal.py - Create PC1PAL binary palette files

Creates 12-byte binary palette files for PC1PAL.COM
Each file contains 4 RGB triples (3 bytes each, values 0-63)

Usage:
    python mkpal.py                     # Creates default palettes
    python mkpal.py output.pal r g b r g b r g b r g b  # Custom palette
"""

import struct
import sys
import os

def create_palette_file(filename, colors):
    """
    Create a binary palette file.
    colors: list of 4 tuples [(r,g,b), (r,g,b), (r,g,b), (r,g,b)]
    Each value 0-63
    """
    with open(filename, 'wb') as f:
        for r, g, b in colors:
            # Clamp values to 0-63
            r = max(0, min(63, r))
            g = max(0, min(63, g))
            b = max(0, min(63, b))
            f.write(struct.pack('BBB', r, g, b))
    print(f"Created: {filename} ({os.path.getsize(filename)} bytes)")

def main():
    # If command line arguments provided, create custom palette
    if len(sys.argv) >= 14:
        filename = sys.argv[1]
        values = [int(x) for x in sys.argv[2:14]]
        colors = [
            (values[0], values[1], values[2]),
            (values[3], values[4], values[5]),
            (values[6], values[7], values[8]),
            (values[9], values[10], values[11]),
        ]
        create_palette_file(filename, colors)
        return
    
    # Otherwise, create all default palettes
    print("Creating default PC1PAL palette files...\n")
    
    # Standard CGA Palette 1: Black, Cyan, Magenta, White
    create_palette_file('CGA_PAL1.PAL', [
        (0, 0, 0),      # Black
        (0, 63, 63),    # Cyan
        (63, 0, 63),    # Magenta
        (63, 63, 63),   # White
    ])
    
    # Standard CGA Palette 0: Black, Green, Red, Yellow
    create_palette_file('CGA_PAL0.PAL', [
        (0, 0, 0),      # Black
        (0, 63, 0),     # Green
        (63, 0, 0),     # Red
        (63, 63, 0),    # Yellow (Brown)
    ])
    
    # High-intensity CGA Palette 1: Black, Light Cyan, Light Magenta, Bright White
    create_palette_file('CGA_HI1.PAL', [
        (0, 0, 0),      # Black
        (21, 63, 63),   # Light Cyan
        (63, 21, 63),   # Light Magenta
        (63, 63, 63),   # Bright White
    ])
    
    # High-intensity CGA Palette 0: Black, Light Green, Light Red, Yellow
    create_palette_file('CGA_HI0.PAL', [
        (0, 0, 0),      # Black
        (21, 63, 21),   # Light Green
        (63, 21, 21),   # Light Red
        (63, 63, 21),   # Yellow
    ])
    
    # Tandy-style enhanced palette
    create_palette_file('TANDY.PAL', [
        (0, 0, 0),      # Black
        (0, 42, 63),    # Sky Blue
        (63, 21, 0),    # Orange
        (63, 63, 63),   # White
    ])
    
    # Grayscale palette
    create_palette_file('GRAY.PAL', [
        (0, 0, 0),      # Black
        (21, 21, 21),   # Dark Gray
        (42, 42, 42),   # Light Gray
        (63, 63, 63),   # White
    ])
    
    # Sepia/Amber palette (for monochrome feel)
    create_palette_file('AMBER.PAL', [
        (0, 0, 0),      # Black
        (21, 14, 0),    # Dark Amber
        (42, 28, 7),    # Medium Amber
        (63, 50, 21),   # Bright Amber
    ])
    
    # Green phosphor monitor style
    create_palette_file('GREEN.PAL', [
        (0, 0, 0),      # Black
        (0, 21, 0),     # Dark Green
        (0, 42, 0),     # Medium Green
        (0, 63, 0),     # Bright Green
    ])
    
    # Cool blue palette
    create_palette_file('BLUE.PAL', [
        (0, 0, 0),      # Black
        (0, 21, 42),    # Dark Blue
        (21, 42, 63),   # Medium Blue
        (42, 63, 63),   # Light Cyan-Blue
    ])
    
    # Warm sunset palette
    create_palette_file('SUNSET.PAL', [
        (0, 0, 0),      # Black
        (42, 0, 21),    # Deep Magenta
        (63, 21, 0),    # Orange
        (63, 63, 0),    # Yellow
    ])
    
    # Default palette (copy as PC1PAL.PAL)
    create_palette_file('PC1PAL.PAL', [
        (0, 0, 0),      # Black
        (0, 63, 63),    # Cyan
        (63, 0, 63),    # Magenta
        (63, 63, 63),   # White
    ])
    
    print("\nDone! Copy your preferred .PAL file to your game directory.")
    print("Rename to PC1PAL.PAL for automatic loading, or specify on command line.")

if __name__ == '__main__':
    main()
