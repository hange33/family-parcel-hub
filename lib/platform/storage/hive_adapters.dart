import 'package:hive/hive.dart';
import '../../core/models/package_status.dart';
import '../../core/models/package.dart';
import 'hive_package.dart';

// ── PackageStatus ──────────────────────────────────────────────

class PackageStatusAdapter extends TypeAdapter<PackageStatus> {
  @override
  final int typeId = 0;

  @override
  PackageStatus read(BinaryReader reader) {
    final index = reader.readByte();
    // 向后兼容：如果索引超出范围，返回pickedUp
    if (index >= PackageStatus.values.length) {
      return PackageStatus.pickedUp;
    }
    return PackageStatus.values[index];
  }

  @override
  void write(BinaryWriter writer, PackageStatus obj) {
    writer.writeByte(obj.index);
  }
}

// ── UrgencyLevel ───────────────────────────────────────────────

class UrgencyLevelAdapter extends TypeAdapter<UrgencyLevel> {
  @override
  final int typeId = 1;

  @override
  UrgencyLevel read(BinaryReader reader) {
    return UrgencyLevel.values[reader.readByte()];
  }

  @override
  void write(BinaryWriter writer, UrgencyLevel obj) {
    writer.writeByte(obj.index);
  }
}

// ── CourierType ────────────────────────────────────────────────

class CourierTypeAdapter extends TypeAdapter<CourierType> {
  @override
  final int typeId = 2;

  @override
  CourierType read(BinaryReader reader) {
    final index = reader.readByte();
    // 向后兼容：如果索引超出范围，返回other
    if (index >= CourierType.values.length) {
      return CourierType.other;
    }
    return CourierType.values[index];
  }

  @override
  void write(BinaryWriter writer, CourierType obj) {
    writer.writeByte(obj.index);
  }
}

// ── HivePackage ────────────────────────────────────────────────

class HivePackageAdapter extends TypeAdapter<HivePackage> {
  @override
  final int typeId = 3;

  @override
  HivePackage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return HivePackage(
      id: fields[0] as String,
      trackingNumber: fields[1] as String,
      courier: fields[2] as CourierType,
      pickupCode: fields[3] as String? ?? '',
      location: fields[4] as String? ?? '',
      description: fields[5] as String? ?? '',
      urgency: fields[6] as UrgencyLevel,
      status: fields[7] as PackageStatus,
      addedAt: fields[8] as DateTime,
      pickedUpAt: fields[9] as DateTime?,
      notifiedArrived: fields[10] as bool? ?? false,
      archivedAt: fields[11] as DateTime?,
      transitFingerprint: fields[12] as String?,
      originalStation: fields[13] as String? ?? '',
      fingerprint: fields[14] as String?,
      goodsName: fields[15] as String?,
      goodsImageUrl: fields[16] as String?,
      platform: fields[17] as String?,
      stationName: fields[18] as String?,
      rawTimelineJson: fields[19] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, HivePackage obj) {
    writer
      ..writeByte(20)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.trackingNumber)
      ..writeByte(2)
      ..write(obj.courier)
      ..writeByte(3)
      ..write(obj.pickupCode)
      ..writeByte(4)
      ..write(obj.location)
      ..writeByte(5)
      ..write(obj.description)
      ..writeByte(6)
      ..write(obj.urgency)
      ..writeByte(7)
      ..write(obj.status)
      ..writeByte(8)
      ..write(obj.addedAt)
      ..writeByte(9)
      ..write(obj.pickedUpAt)
      ..writeByte(10)
      ..write(obj.notifiedArrived)
      ..writeByte(11)
      ..write(obj.archivedAt)
      ..writeByte(12)
      ..write(obj.transitFingerprint)
      ..writeByte(13)
      ..write(obj.originalStation)
      ..writeByte(14)
      ..write(obj.fingerprint)
      ..writeByte(15)
      ..write(obj.goodsName)
      ..writeByte(16)
      ..write(obj.goodsImageUrl)
      ..writeByte(17)
      ..write(obj.platform)
      ..writeByte(18)
      ..write(obj.stationName)
      ..writeByte(19)
      ..write(obj.rawTimelineJson);
  }
}
