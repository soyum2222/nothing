clone:
	git clone https://github.com/soyum2222/soyum2222.github.io

pull:clone
	cd soyum2222.github.io && git pull


build:pull
	hugo --baseUrl="https://soyum2222.github.io"
	cp -r ./public/* soyum2222.github.io

push:build
	cd soyum2222.github.io && git add . 
	cd soyum2222.github.io && git commit -m "update something"
	cd soyum2222.github.io && git push

