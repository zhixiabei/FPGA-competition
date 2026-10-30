"""Independent arithmetic checks only; does not compile, simulate or build RTL.

Checks the proposed fixed-width datapaths against multiplication/division,
decimal formatting and indexed selection. HDL scheduling and physical timing
still require the existing component benches and a user-run FPGA build.
"""
import random


def serial_product(weight, unit):
    product = 0
    for _ in range(12):
        partial = (product >> 12) + (weight if unit & 1 else 0)
        assert partial < 1 << 15
        product = (partial << 11) | ((product >> 1) & 0x7FF)
        unit >>= 1
    return product


def shared_subtract_divide(numerator, denominator):
    bits, remainder, quotient = numerator, 0, 0
    for _ in range(35):
        trial = (remainder << 1) | (bits >> 34)
        difference = (trial - denominator) & ((1 << 27) - 1)
        take = 1 ^ (difference >> 26)
        assert bool(take) == (trial >= denominator)
        remainder = (difference if take else trial) & ((1 << 25) - 1)
        bits = (bits << 1) & ((1 << 35) - 1)
        quotient = (quotient << 1) | take
    return quotient


def decimal_pair(weight, price):
    conversion, binary = 0, (weight << 14) | price
    for _ in range(14):
        corrected = conversion
        for digit in range(8):
            nibble = (conversion >> (4 * digit)) & 15
            if nibble >= 5:
                corrected += 3 << (4 * digit)
        conversion = (((corrected >> 16) & 0x7FFF) << 17)
        conversion |= ((binary >> 27) & 1) << 16
        conversion |= (corrected & 0x7FFF) << 1
        conversion |= (binary >> 13) & 1
        binary = (((binary >> 14) & 0x1FFF) << 15) | ((binary & 0x1FFF) << 1)
    return conversion


def main():
    rng = random.Random(20261030)
    counts = {}
    prices = (0, 1, 499, 500, 600, 800, 1000, 1200, 2000, 4095)
    for weight in range(1 << 14):
        for unit in prices:
            assert serial_product(weight, unit) == weight * unit
    for _ in range(10000):
        weight, unit = rng.randrange(1 << 14), rng.randrange(1 << 12)
        assert serial_product(weight, unit) == weight * unit
    counts['price_products'] = (1 << 14) * len(prices) + 10000

    numerators = (0, 1, 499, 500, 999, 1000, 9999499, 9999500, (1 << 35) - 1)
    denominators = (1, 2, 3, 999, 1000, (1 << 24), (1 << 25) - 1)
    for n in numerators:
        for d in denominators:
            assert shared_subtract_divide(n, d) == n // d
        # Preserve the previous divider's defined all-ones output for zero.
        assert shared_subtract_divide(n, 0) == (1 << 35) - 1
    for _ in range(10000):
        n, d = rng.randrange(1 << 35), rng.randrange(1, 1 << 25)
        assert shared_subtract_divide(n, d) == n // d
    counts['divisions'] = len(numerators) * (len(denominators) + 1) + 10000

    for weight in range(10000):
        price = 9999 - weight
        assert decimal_pair(weight, price) == int(f'{weight:04d}{price:04d}', 16)
    counts['decimal_pairs'] = 10000

    for y in range(160):
        for x in range(160):
            assert (((y << 7) + (y << 5) + x) & 0x7FFF) == y * 160 + x
    counts['logo_pixels'] = 160 * 160

    for _ in range(1000):
        sums = [rng.getrandbits(54) for _ in range(24)]
        bus = sum(value << (54 * i) for i, value in enumerate(sums))
        for lane in range(24):
            selected = 0
            for i, value in enumerate(sums):
                selected |= (value & 0xFFFFFFFF) if lane == i else 0
            assert selected == ((bus >> (54 * lane)) & 0xFFFFFFFF)
    counts['lane_selections'] = 24000

    # Cover misses, all four hit slots, invalid lines and duplicate tags.
    for valid_mask in range(16):
        for tag_mask in range(16):
            tags = [31 if tag_mask & (1 << i) else 63 for i in range(4)]
            data = [rng.getrandbits(96) for _ in range(4)]
            for pool in (False, True):
                conv_address, pool_address = 31, 63
                old_hits = [[bool(valid_mask & (1 << i)) and tags[i] == address
                             for i in range(4)] for address in (conv_address, pool_address)]
                address = pool_address if pool else conv_address
                hits = [bool(valid_mask & (1 << i)) and tags[i] == address for i in range(4)]
                assert hits == old_hits[int(pool)]
                old_index = next((i for i in range(3) if old_hits[int(pool)][i]), 3)
                new_index = next((i for i in range(3) if hits[i]), 3)
                assert data[old_index] == data[new_index]
    counts['cache_queries'] = 512
    print('FRUIT_RESOURCE_MATH_PASS', counts)
    print('Software arithmetic checks only; RTL simulation and synthesis were not run.')


if __name__ == '__main__':
    main()
