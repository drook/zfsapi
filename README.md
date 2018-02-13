#ZFS API for the playkey.net.

##Последоватальность действий при обращении с zfs-api (после всех правок в CLOUDGAMES-14051):

1. Отключение таргета в системе:

    MS Windows: см: CLOUDGAMES-14157
    linux:

    ```$ sudo iscsiadm -m node -T iqn.2016-04.net.playkey.iscsi:test-ver02 -u```

2. Оставка диска: http://192.168.31.52/api?action=release&victim=dataflash/kvm/test-ver02
3. Удаление клона: http://192.168.31.52/api?action=destroy&victim=dataflash/kvm/test-ver02
4. Создание клона: http://192.168.31.52/api?action=clone&clonesource=dataflash/kvm/guest1@ver1&clonename=dataflash/kvm/test-ver02
5. Начало использования диска: http://192.168.31.52/api?action=targetcreate&targetname=/dev/zvol/dataflash/kvm/test-ver02&deviceid=test-ver0x&iscsiname=iqn.2016-04.net.playkey.iscsi:test-ver02,lun,0&lunid=40&vendor=FREE_TT
6. Подключение таргета в системе:

    MS Windows: см. CLOUDGAMES-14157

    linux:
    ```$ sudo iscsiadm -m node -T iqn.2016-04.net.playkey.iscsi:test-ver02 -l```

    , где
    - `192.168.31.52` - сервер на который кидаются запросы zfs-api
    - `iqn.2016-04.net.playkey.iscsi:test-ver02` - имя таргета
    - ` dataflash/kvm/test-ver02` - укороченное имя клона
    - `dataflash/kvm/guest1@ver1` - имя снапшота, с которого "снимается" клон
    - `/dev/zvol/dataflash/kvm/test-ver02` - длинное имя клона
    - `test-ver0x` - device-id
    - `40` - lun диска
    - `FREE_TT` - вендор

##Прочее

###Формат имени диска в системе linux, использующей подключённые диски:

```/dev/disk/by-id/scsi-1[FREE_TT]_[test-ver0x]```

###Запросы на получение информации о дисках и клонах:

- информация о таргете: http://192.168.31.52/apiaction=targetinfotargetname=iqn.2016-04.net.playkeyiscsi:test-ver02
список текущих клонов, дисков, снепшотам:http://192.168.31.52/api?action=status

- Пример настроенного на дисковой стойке таргета (из файла `/etc/ctl.conf`):

    ```target iqn.2016-04.net.playkey.iscsi:test-ver02 {
        initiator-portal 192.168.1.72/32
        portal-group playkey
        auth-type none
        lun 0 {
            ctl-lun 40
            device-id test-ver0x
            path /dev/zvol/dataflash/kvm/test-ver02
            serial 444
            option vendor FREE_TT
        }
    }
    ```

- Выдача на дисковой стойке по запросу:

    ```
    $ sudo ctladm devlist -v
    ....
    40 block             104857600  512 MYSERIAL  16     test-ver0x      
        lun_type=0
        num_threads=14
        file=/dev/zvol/dataflash/kvm/test-ver02
        vendor=FREE_TT
        scsiname=iqn.2016-04.net.playkey.iscsi:test-ver02,lun,0
        ctld_name=iqn.2016-04.net.playkey.iscsi:test-ver02,lun,0
    ```
