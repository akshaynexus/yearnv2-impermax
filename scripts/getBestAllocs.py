def main():
    #Paste data output from getAllFTMLendingpools script to calculate allocation
    #TODO move this to getallftmlendingpools script
    lendingData = [
        [
            "0x9cDED654472788a143C2285A6b2a580392510688",
            88.92197756260941,
            53408.96958723915,
            5916.657634453473,
        ],
        [
            "0xDf79EA5d777F28cAb9fD42ACda6208a228c71B59",
            88.3393891743857,
            142438.39236093525,
            16609.18659947018,
        ],
        [
            "0xF2D3AE45F8775bA0a729dF47210164F921Edc306",
            87.32353001774126,
            148816.79801055187,
            18864.71672836623,
        ],
        [
            "0x37F6Cf24bA9E781344Ae4aC8923d9A0A3910bc64",
            86.78115980063802,
            56298.55006196227,
            7442.0153672485985,
        ],
        [
            "0x0c60dbD5b78d1488F9f71163E598d90f8EDE55E7",
            85.86208535497201,
            55825.258222337936,
            7892.527357840609,
        ],
        [
            "0x4e4a8AE836cBE9576113706e166ae1194A7113E6",
            84.998080712831,
            155816.63446025588,
            23375.48573771075,
        ],
        [
            "0x00Fb23C7169E0378a63D9cFE50Ef40f944653c69",
            83.54515754598836,
            57391.835959254255,
            9443.736188560088,
        ],
        [
            "0xB566727F4edF30bA13939E304d828e30d4063C59",
            77.49255682620067,
            173755.01519852533,
            39107.81130743449,
        ],
        [
            "0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3",
            62.0503877793915,
            2135230.6989347083,
            810311.7702611102,
        ],
        [
            "0x5dd76071F7b5F4599d4F2B7c08641843B746ace9",
            61.518121323351714,
            2226213.7441787124,
            856688.8721177216,
        ],
    ]
    totalUtil = 0
    totalAlloc = 0
    poolAllocConf = []
    # First get total util points
    for lendingPool in lendingData:
        # Do not lend to low utilization lending pools
        if lendingPool[1] < 20:
            continue
        totalUtil = totalUtil + lendingPool[1]
    for lendingPool in lendingData:
        allocPoints = lendingPool[1] / totalUtil
        allocPoints = round((allocPoints * 100) * 100)
        totalAlloc = totalAlloc + allocPoints
        poolAllocConf.append([lendingPool[0], allocPoints])
    print(totalAlloc)
    if totalAlloc < 10000:
        poolAllocConf[-1][1] = poolAllocConf[-1][1] + (10000 - totalAlloc)
    print(poolAllocConf)


main()
