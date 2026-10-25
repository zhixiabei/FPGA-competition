"""Result confirmation shared by the live desktop preview and RTL checks."""

LABELS = ('NOTHING', 'PEACE', 'PUNCH', 'STOP')


class ResultFilter:
    def __init__(self):
        self.clear()

    def clear(self):
        self.stable = 1
        self.candidate = 1
        self.count = 0
        return self.stable

    def update(self, class_id, *, clear=False):
        if clear:
            return self.clear()
        if class_id not in (1, 2, 3, 4):
            raise ValueError('Expected NOTHING/PEACE/PUNCH/STOP class ID 1..4')
        if class_id == self.stable:
            self.candidate, self.count = 1, 0
        else:
            self.count = self.count+1 if class_id == self.candidate else 1
            self.candidate = class_id
            required = 2 if self.stable == 1 and class_id != 1 else 3
            if self.count >= required:
                self.stable = class_id
                self.candidate, self.count = 1, 0
        return self.stable
