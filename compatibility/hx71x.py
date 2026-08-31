# HX711/HX717 Support
#
# Copyright (C) 2024 Gareth Farrington <gareth@waves.ky>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
from . import bulk_sensor


UPDATE_INTERVAL = 0.10
SAMPLE_ERROR_DESYNC = -0x80000000
SAMPLE_ERROR_LONG_READ = 0x40000000


class HX71xBase:
    def __init__(self, config, sensor_type, sample_rate_options,
                 default_sample_rate, gain_options, default_gain):
        self.printer = printer = config.get_printer()
        self.name = config.get_name().split()[-1]
        self.last_error_count = 0
        self.consecutive_fails = 0
        self.sensor_type = sensor_type
        dout_pin_name = config.get('dout_pin')
        sclk_pin_name = config.get('sclk_pin')
        ppins = printer.lookup_object('pins')
        dout_ppin = ppins.lookup_pin(dout_pin_name)
        sclk_ppin = ppins.lookup_pin(sclk_pin_name)
        self.mcu = mcu = dout_ppin['chip']
        self.oid = mcu.create_oid()
        if sclk_ppin['chip'] is not mcu:
            raise config.error("%s config error: All pins must be "
                               "connected to the same MCU" % (self.name,))
        self.dout_pin = dout_ppin['pin']
        self.sclk_pin = sclk_ppin['pin']
        self.sps = config.getchoice('sample_rate', sample_rate_options,
                                    default=default_sample_rate)
        self.gain_channel = int(config.getchoice(
            'gain', gain_options, default=default_gain))
        chip_smooth = self.sps * UPDATE_INTERVAL * 2
        self.ffreader = bulk_sensor.FixedFreqReader(mcu, chip_smooth, "<i")
        self.batch_bulk = bulk_sensor.BatchBulkHelper(
            self.printer, self._process_batch, self._start_measurements,
            self._finish_measurements, UPDATE_INTERVAL)
        self.query_hx71x_cmd = None
        mcu.add_config_cmd(
            "config_hx71x oid=%d gain_channel=%d dout_pin=%s sclk_pin=%s"
            % (self.oid, self.gain_channel, self.dout_pin, self.sclk_pin))
        mcu.add_config_cmd("query_hx71x oid=%d rest_ticks=0"
                           % (self.oid,), on_restart=True)
        mcu.register_config_callback(self._build_config)

    def setup_trigger_analog(self, trigger_analog_oid):
        self.mcu.add_config_cmd(
            "hx71x_attach_trigger_analog oid=%d trigger_analog_oid=%d"
            % (self.oid, trigger_analog_oid), is_init=True)

    def _build_config(self):
        cmd_queue = self.mcu.alloc_command_queue()
        self.query_hx71x_cmd = self.mcu.lookup_command(
            "query_hx71x oid=%c rest_ticks=%u", cq=cmd_queue)
        self.ffreader.setup_query_command("query_hx71x_status oid=%c",
                                          oid=self.oid, cq=cmd_queue)

    def get_mcu(self):
        return self.mcu

    def get_samples_per_second(self):
        return self.sps

    def get_status(self, eventtime):
        return {
            'errors': self.last_error_count,
            'overflows': self.ffreader.get_last_overflows(),
            'sample_rate': self.get_samples_per_second(),
        }

    def lookup_sensor_error(self, error_code):
        return "Unknown hx71x error %d" % (error_code,)

    def get_range(self):
        return -0x800000, 0x7fffff

    def add_client(self, callback):
        self.batch_bulk.add_client(callback)

    def _convert_samples(self, samples):
        adc_factor = 1. / (1 << 23)
        count = 0
        for ptime, val in samples:
            if val == SAMPLE_ERROR_DESYNC or val == SAMPLE_ERROR_LONG_READ:
                self.last_error_count += 1
                break
            samples[count] = (round(ptime, 6), val,
                              round(val * adc_factor, 9))
            count += 1
        del samples[count:]

    def _start_measurements(self):
        self.consecutive_fails = 0
        self.last_error_count = 0
        rest_ticks = self.mcu.seconds_to_clock(1. / (10. * self.sps))
        self.query_hx71x_cmd.send([self.oid, rest_ticks])
        logging.info("%s starting '%s' measurements",
                     self.sensor_type, self.name)
        self.ffreader.note_start()

    def _finish_measurements(self):
        if self.printer.is_shutdown():
            return
        self.query_hx71x_cmd.send_wait_ack([self.oid, 0])
        self.ffreader.note_end()
        logging.info("%s finished '%s' measurements",
                     self.sensor_type, self.name)

    def _process_batch(self, eventtime):
        prev_overflows = self.ffreader.get_last_overflows()
        prev_error_count = self.last_error_count
        samples = self.ffreader.pull_samples()
        self._convert_samples(samples)
        overflows = self.ffreader.get_last_overflows() - prev_overflows
        errors = self.last_error_count - prev_error_count
        if errors > 0:
            logging.error("%s: Forced sensor restart due to error", self.name)
            self._finish_measurements()
            self._start_measurements()
        elif overflows > 0:
            self.consecutive_fails += 1
            if self.consecutive_fails > 4:
                logging.error("%s: Forced sensor restart due to overflows",
                              self.name)
                self._finish_measurements()
                self._start_measurements()
        else:
            self.consecutive_fails = 0
        return {'data': samples, 'errors': self.last_error_count,
                'overflows': self.ffreader.get_last_overflows()}


def HX711(config):
    return HX71xBase(config, "hx711", {80: 80, 10: 10}, 80,
                     {'A-128': 1, 'B-32': 2, 'A-64': 3}, 'A-128')


def HX717(config):
    return HX71xBase(config, "hx717", {320: 320, 80: 80, 20: 20, 10: 10},
                     320, {'A-128': 1, 'B-64': 2, 'A-64': 3, 'B-8': 4},
                     'A-128')


# Native-reader four-HX711 aggregate sensor. Each converter is clocked
# independently on the leveling MCU, then one fresh sample per channel is
# summed before trigger_analog update. Motion stopping remains MCU-side.
class HX711Quad(HX71xBase):
    def __init__(self, config):
        self.printer = printer = config.get_printer()
        self.name = config.get_name().split()[-1]
        self.last_error_count = 0
        self.consecutive_fails = 0
        self.sensor_type = "hx711_quad"
        self.lifetime_error_counts = {
            'desync': 0, 'read_too_long': 0, 'saturated': 0,
        }
        self.last_error_code = 0
        self.last_desync_mask = 0
        ppins = printer.lookup_object('pins')
        pin_pairs = []
        mcu = None
        for index in range(4):
            dout_ppin = ppins.lookup_pin(config.get('dout_pin_%d' % index))
            sclk_ppin = ppins.lookup_pin(config.get('sclk_pin_%d' % index))
            if mcu is None:
                mcu = dout_ppin['chip']
            if dout_ppin['chip'] is not mcu or sclk_ppin['chip'] is not mcu:
                raise config.error("%s config error: All pins must be "
                                   "connected to the same MCU" % self.name)
            pin_pairs.append((dout_ppin['pin'], sclk_ppin['pin']))
        self.mcu = mcu
        self.oid = mcu.create_oid()
        self.sps = config.getchoice('sample_rate', {80: 80, 10: 10},
                                    default=80)
        self.gain_channel = int(config.getchoice(
            'gain', {'A-128': 1, 'B-32': 2, 'A-64': 3}, default='A-128'))
        self.invert_mask = config.getint('channel_invert_mask', 0,
                                         minval=0, maxval=15)
        chip_smooth = self.sps * UPDATE_INTERVAL * 2
        self.ffreader = bulk_sensor.FixedFreqReader(mcu, chip_smooth, "<i")
        self.batch_bulk = bulk_sensor.BatchBulkHelper(
            self.printer, self._process_batch, self._start_measurements,
            self._finish_measurements, UPDATE_INTERVAL)
        self.query_hx71x_cmd = None
        flat_pins = [pin for pair in pin_pairs for pin in pair]
        mcu.add_config_cmd(
            ("config_hx71x_quad oid=%d gain_channel=%d invert_mask=%d "
             "dout0_pin=%s sclk0_pin=%s dout1_pin=%s sclk1_pin=%s "
             "dout2_pin=%s sclk2_pin=%s dout3_pin=%s sclk3_pin=%s")
            % tuple([self.oid, self.gain_channel, self.invert_mask]
                    + flat_pins))
        mcu.add_config_cmd("query_hx71x_quad oid=%d rest_ticks=0"
                           % self.oid, on_restart=True)
        mcu.register_config_callback(self._build_config)

    def setup_trigger_analog(self, trigger_analog_oid):
        self.mcu.add_config_cmd(
            "hx71x_quad_attach_trigger_analog oid=%d trigger_analog_oid=%d"
            % (self.oid, trigger_analog_oid), is_init=True)

    def _build_config(self):
        cmd_queue = self.mcu.alloc_command_queue()
        self.query_hx71x_cmd = self.mcu.lookup_command(
            "query_hx71x_quad oid=%c rest_ticks=%u", cq=cmd_queue)
        self.ffreader.setup_query_command("query_hx71x_quad_status oid=%c",
                                          oid=self.oid, cq=cmd_queue)

    def get_range(self):
        return -0x2000000, 0x1fffffc

    def get_status(self, eventtime):
        status = super(HX711Quad, self).get_status(eventtime)
        status.update({
            'last_error_code': self.last_error_code,
            'last_desync_mask': self.last_desync_mask,
            'desync_errors': self.lifetime_error_counts['desync'],
            'read_too_long_errors':
                self.lifetime_error_counts['read_too_long'],
            'saturated_errors': self.lifetime_error_counts['saturated'],
            'lifetime_errors': sum(self.lifetime_error_counts.values()),
        })
        return status

    def _convert_samples(self, samples):
        adc_factor = 1. / (1 << 25)
        count = 0
        for ptime, val in samples:
            error_u32 = val & 0xffffffff
            error_base = error_u32 & 0xfffffff0
            if error_base == 0x80000000:
                error_name = 'desync'
            elif error_base == SAMPLE_ERROR_LONG_READ:
                error_name = 'read_too_long'
            elif error_base == 0x20000000:
                error_name = 'saturated'
            else:
                error_name = None
            if error_name is not None:
                self.last_desync_mask = error_u32 & 0x0f
                self.last_error_count += 1
                self.lifetime_error_counts[error_name] += 1
                self.last_error_code = val
                logging.error(
                    "%s: HX711 aggregate %s error code %d channel_mask=%d",
                    self.name, error_name, val, self.last_desync_mask)
                break
            samples[count] = (round(ptime, 6), val,
                              round(val * adc_factor, 9))
            count += 1
        del samples[count:]

    def lookup_sensor_error(self, error_code):
        error_base = error_code & 0xfffffff0
        if error_base == 0x80000000:
            return "At least one HX711 channel lost framing"
        if error_base == SAMPLE_ERROR_LONG_READ:
            return "At least one HX711 read did not finish before its next sample"
        if error_base == 0x20000000:
            return "At least one HX711 channel is saturated"
        return super(HX711Quad, self).lookup_sensor_error(error_code)


def HX711_QUAD(config):
    return HX711Quad(config)


HX71X_SENSOR_TYPES = {
    "hx711": HX711,
    "hx717": HX717,
    "hx711_quad": HX711_QUAD,
}
