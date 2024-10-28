QUARTUS_DIR = C:/intelFPGA_lite/17.0/quartus/bin64
PROJECT = Arcade-IremM90
CONFIG = Arcade-IremM90-Fast
MISTER = root@mister-dev

build: 
	$(QUARTUS_DIR)/quartus_map --read_settings_files=on --write_settings_files=off $(PROJECT) -c $(CONFIG)
	$(QUARTUS_DIR)/quartus_fit --read_settings_files=on --write_settings_files=off $(PROJECT) -c $(CONFIG)
	$(QUARTUS_DIR)/quartus_asm --read_settings_files=on --write_settings_files=off $(PROJECT) -c $(CONFIG)
	$(QUARTUS_DIR)/quartus_sta $(PROJECT) -c $(CONFIG)

deploy:
	scp output_files/$(CONFIG).rbf $(MISTER):/media/fat/_Arcade/cores/IremM90.rbf

run:
	ssh $(MISTER) "echo load_core _Arcade/m90.mra > /dev/MiSTer_cmd"

all: build deploy run