$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Exhaustively compare the old paired-channel inequalities with the shared
# max/min form. Enumerating dominant/A/B covers every RGB permutation; the
# green branch uses the relaxed test, while red and blue use the strict test.
Add-Type -TypeDefinition @'
public static class ColorMaskEquivalence {
    public static void Run() {
        int[] deltas = {0, 6, 256, 257, 511};
        long comparisons = 0;
        long strictHits = 0, greenHits = 0;
        foreach (int delta in deltas) {
            for (int dominant = 0; dominant < 256; dominant++) {
                for (int a = 0; a < 256; a++) {
                    for (int b = 0; b < 256; b++) {
                        int oldLimitA = (a + delta) & 511;
                        int oldLimitB = (b + delta) & 511;
                        bool oldDelta = dominant >= oldLimitA &&
                                        dominant >= oldLimitB;
                        bool oldStrict = dominant >= 24 && oldDelta &&
                            2 * dominant >= 3 * a &&
                            2 * dominant >= 3 * b &&
                            3 * a <= dominant + 2 * b &&
                            3 * b <= dominant + 2 * a;
                        bool oldGreen = dominant >= 24 && oldDelta &&
                            4 * dominant >= 5 * a &&
                            4 * dominant >= 5 * b;
                        int largest = System.Math.Max(a, b);
                        int smallest = System.Math.Min(a, b);
                        bool newDelta = delta <= 256
                            ? dominant >= ((largest + delta) & 511)
                            : dominant >= oldLimitA && dominant >= oldLimitB;
                        bool newStrict = dominant >= 24 && newDelta &&
                            2 * dominant >= 3 * largest &&
                            3 * largest <= dominant + 2 * smallest;
                        bool newGreen = dominant >= 24 && newDelta &&
                            4 * dominant >= 5 * largest;
                        if (oldStrict != newStrict || oldGreen != newGreen)
                            throw new System.InvalidOperationException(
                                "Color mask mismatch at D/A/B/delta=" +
                                dominant + "/" + a + "/" + b + "/" + delta);
                        comparisons += 2;
                        if (delta == 6) {
                            if (newStrict) strictHits++;
                            if (newGreen) greenHits++;
                        }
                    }
                }
            }
        }
        System.Console.WriteLine(
            "COLOR_MASK_EQUIVALENCE_PASS rgb_values=16777216 " +
            "deltas=0,6,256,257,511 comparisons=" + comparisons +
            " strict_hits_delta6=" + strictHits +
            " green_hits_delta6=" + greenHits);
    }
}
'@ -Language CSharp
[ColorMaskEquivalence]::Run()
