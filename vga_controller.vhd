-------------------------------------------------------------------------------
--
-- A VGA line-doubler for an Apple ][
--
-- Stephen A. Edwards, sedwards@cs.columbia.edu
--
--
-- FIXME: This is all wrong
--
-- The Apple ][ uses a 14.31818 MHz master clock.  It outputs a new
-- horizontal line every 65 * 14 + 2 = 912 14M cycles.  The extra two
-- are from the "extended cycle" used to keep the 3.579545 MHz
-- colorburst signal in sync.  Of these, 40 * 14 = 560 are active video.
--
-- In graphics mode, the Apple effectively generates 140 four-bit pixels
-- output serially (i.e., with 3.579545 MHz pixel clock).  In text mode,
-- it generates 280 one-bit pixels (i.e., with a 7.15909 MHz pixel clock).
--
-- We capture 140 four-bit nibbles for each line and interpret them in
-- one of the two modes.  In graphics mode, each is displayed as a
-- single pixel of one of 16 colors.  In text mode, each is displayed
-- as two black or white pixels.
-- 
-- The VGA display is nominally 640 X 480, but we use a 14.31818 MHz
-- dot clock.  To stay in sync with the Apple, we generate a new line
-- every 912 / 2 = 456 14M cycles= 31.8 us, a 31.4 kHz horizontal
-- refresh rate.  Of these, 280 will be active video.
--
-- One set of suggested VGA timings:
--
--          ______________________          ________
-- ________|        VIDEO         |________| VIDEO
--     |-C-|----------D-----------|-E-|
-- __   ______________________________   ___________
--   |_|                              |_|
--   |B|
--   |---------------A----------------|
--
-- A = 31.77 us	 Scanline time
-- B =  3.77 us  Horizontal sync time
-- C =  1.89 us  Back porch
-- D = 25.17 us  Active video
-- E =  0.94 us  Front porch
--
-- We use A = 456 / 14.31818 MHz = 31.84 us
--        B =  54 / 14.31818 MHz =  3.77 us
--        C = 106 / 14.31818 MHz =  7.40 us
--        D = 280 / 14.31818 MHz = 19.56 us
--        E =  16 / 14.31818 MHz =  1.12 us
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vga_controller is
  
  port (
    CLK_28M    : in  std_logic;	     -- 14.31818 MHz master clock

    VIDEO      : in std_logic;         -- from the Apple video generator
    COLOR_LINE : in std_logic;
	 SCREEN_MODE: in std_logic_vector(1 downto 0); -- 00: Color, 01: B&W, 10: Green, 11: Amber
    HBL        : in std_logic;
    VBL        : in std_logic;
    LD194      : in std_logic;
    
    VGA_CLK    : out std_logic;
    VGA_HS     : out std_logic;             -- Active low
    VGA_VS     : out std_logic;             -- Active low
    VGA_DE     : out std_logic;
    VGA_R      : out unsigned(7 downto 0);
    VGA_G      : out unsigned(7 downto 0);
    VGA_B      : out unsigned(7 downto 0)
    );
  
end vga_controller;

architecture rtl of vga_controller is

  -- Double-ported RAM (one read port, one write port)
  -- that holds two lines of 560 pixels
  type line_memory_t is array (0 to 2047) of std_logic;
  signal line_memory : line_memory_t;

  -- RGB values from Linards Ticmanis,
  -- http://newsgroups.derkeiler.com/Archive/Comp/comp.sys.apple2/2005-09/msg00534.html

  type basis_color is array(0 to 3) of unsigned(7 downto 0);
  constant basis_r : basis_color := ( X"88", X"38", X"07", X"38" );
  constant basis_g : basis_color := ( X"22", X"24", X"67", X"52" );
  constant basis_b : basis_color := ( X"2C", X"A0", X"2C", X"07" );

  signal ram_write_addr : unsigned(10 downto 0);
  signal ram_we : std_logic;
  signal ram_read_addr : unsigned(10 downto 0);
  signal ram_data_out : std_logic;

  signal shift_reg : unsigned(5 downto 0);  -- Last six pixels

  signal last_hbl : std_logic;
  signal hcount : unsigned(10 downto 0);
  signal hcount2 : unsigned(10 downto 0);
  signal vcount : unsigned(5 downto 0);
  signal even_line : std_logic;
  signal hactive, hactive_early2, hactive_early1 : std_logic;

  constant VGA_SCANLINE : integer := 456*2; -- Must be 456*2 (set by the Apple)
  
  constant VGA_HSYNC : integer := 54 * 2;
  constant VGA_BACK_PORCH : integer := 66 * 2;
  constant VGA_ACTIVE : integer := 282 * 2;
  constant VGA_FRONT_PORCH : integer := 54 * 2;

  -- VGA_HSYNC + VGA_BACK_PORCH + VGA_ACTIVE + VGA_FRONT_PORCH = VGA_SCANLINE

  constant VBL_TO_VSYNC : integer := 33;
  constant VGA_VSYNC_LINES : integer := 3;

  signal VGA_VS_I, VGA_HS_I : std_logic;

  signal video_active : std_logic;
  signal vbl_delayed, vbl_delayed2 : std_logic;
  signal hbl_delayed : std_logic;
  signal color_line_delayed_1, color_line_delayed_2 : std_logic;

begin
 
  delay_hbl : process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      if LD194 = '0' then
        hbl_delayed <= HBL;
      end if;
    end if;
  end process;

  hcount_vcount_control : process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      if last_hbl = '1' and hbl_delayed = '0' then  -- Falling edge
        color_line_delayed_2 <= color_line_delayed_1;
        color_line_delayed_1 <= COLOR_LINE;
        hcount <= (others => '0');
        vbl_delayed2 <= vbl_delayed;
        vbl_delayed <= VBL;
        if vbl_delayed = '1' then
          even_line <= '0';
          vcount <= vcount + 1;
        else
          vcount <= (others => '0');
          even_line <= not even_line;
        end if;
      else
        hcount <= hcount + 1;
      end if;
      last_hbl <= hbl_delayed;
    end if;
  end process hcount_vcount_control;

  hsync_gen : process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      if hcount = VGA_ACTIVE + VGA_FRONT_PORCH or
        hcount = VGA_SCANLINE + VGA_ACTIVE + VGA_FRONT_PORCH then
        VGA_HS_I <= '0';
      elsif hcount = VGA_ACTIVE + VGA_FRONT_PORCH + VGA_HSYNC or
        hcount = VGA_SCANLINE + VGA_ACTIVE + VGA_FRONT_PORCH + VGA_HSYNC then
        VGA_HS_I <= '1';
      end if;

      hactive <= hactive_early1;
      hactive_early1 <= hactive_early2;

      if hcount = VGA_SCANLINE - 1 or
        hcount = VGA_SCANLINE + VGA_SCANLINE - 1 then
        hactive_early2 <= '1';
      elsif hcount = VGA_ACTIVE or
        hcount = VGA_ACTIVE + VGA_SCANLINE then
        hactive_early2 <= '0';
      end if;
    end if;
  end process hsync_gen;

  VGA_HS <= VGA_HS_I;

  vsync_gen : process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      if vcount = VBL_TO_VSYNC then
        VGA_VS_I <= '0';
      elsif vcount = VBL_TO_VSYNC + VGA_VSYNC_LINES then
        VGA_VS_I <= '1';
      end if;
    end if;
  end process vsync_gen;

  VGA_VS <= VGA_VS_I;

  hcount2 <= hcount - VGA_SCANLINE;

  ram_read_addr <=
    even_line & hcount(9 downto 0) when hcount < VGA_SCANLINE else
    even_line & hcount2(9 downto 0);

  shifter: process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      shift_reg <= ram_data_out & shift_reg(5 downto 1);
    end if;
  end process;
  
  ram_write_addr <= (not even_line) & hcount(10 downto 1);
  ram_we <= '1' when hcount(0) = '1' else '0';

  video_active <= hactive and not vbl_delayed2;

  pixel_generator: process (CLK_28M)
    variable r, g, b : unsigned(7 downto 0); 
  begin
    if rising_edge(CLK_28M) then
	 
      r := X"00";
      g := X"00"; 
      b := X"00"; 
		
		-- alternate background for monochrome modes
		case SCREEN_MODE is 
			when "00" =>
				r := X"00"; g := X"00"; b := X"00"; -- color mode background
			when "01" => 
				r := X"00"; g := X"00"; b := X"00"; -- B&W mode background
			when "10" =>
				r := X"00"; g := X"0F"; b := X"01"; -- green mode background color
			when "11" =>
				r := X"20"; g := X"08"; b := X"01"; -- amber mode background color
		end case;
		
      if video_active = '1' then
        
        if color_line_delayed_2 = '0' then  -- Monochrome mode
          
			 if shift_reg(2) = '1' then
				-- handle green/amber color modes
				case SCREEN_MODE is 
					when "00" => 
						r := X"FF"; g := X"FF"; b := X"FF"; -- white (color mode)
					when "01" => 
						r := X"FF"; g := X"FF"; b := X"FF"; -- white (B&W mode)
					when "10" =>
						r := X"00"; g := X"C0"; b := X"01"; -- green
					when "11" =>
						r := X"FF"; g := X"80"; b := X"01"; -- amber 
				end case;
			 end if;
          
        elsif shift_reg(0) = shift_reg(4) and shift_reg(5) = shift_reg(1) then
          
          -- Tint of adjacent pixels is consistent : display the color
          
          if shift_reg(1) = '1' then
            r := r + basis_r(to_integer(hcount + 1));
            g := g + basis_g(to_integer(hcount + 1));
            b := b + basis_b(to_integer(hcount + 1));
          end if;
          if shift_reg(2) = '1' then
            r := r + basis_r(to_integer(hcount + 2));
            g := g + basis_g(to_integer(hcount + 2));
            b := b + basis_b(to_integer(hcount + 2));
          end if;
          if shift_reg(3) = '1' then
            r := r + basis_r(to_integer(hcount + 3));
            g := g + basis_g(to_integer(hcount + 3));
            b := b + basis_b(to_integer(hcount + 3));
          end if;
          if shift_reg(4) = '1' then
            r := r + basis_r(to_integer(hcount));
            g := g + basis_g(to_integer(hcount));
            b := b + basis_b(to_integer(hcount));
          end if;
        else
          
          -- Tint is changing: display only black, gray, or white
          
          case shift_reg(3 downto 2) is
            when "11"        => r := X"FF"; g := X"FF"; b := X"FF";
            when "01" | "10" => r := X"80"; g := X"80"; b := X"80";
            when others      => r := X"00"; g := X"00"; b := X"00";
          end case;
        end if;
        
      end if;
      
      VGA_R <= r;
      VGA_G <= g;
      VGA_B <= b;
      
    end if;
  end process pixel_generator;

  -- The two-port RAM that stores the line data
  line_storage : process (CLK_28M)
  begin
    if rising_edge(CLK_28M) then
      if ram_we = '1' then
        line_memory(to_integer(ram_write_addr)) <= VIDEO;
      end if;
      ram_data_out <= line_memory(to_integer(ram_read_addr));
    end if;
  end process line_storage;

  VGA_CLK <= CLK_28M;
  VGA_DE <= video_active;

end rtl;
