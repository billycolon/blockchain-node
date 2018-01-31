# coding: utf-8

"""
    Aeternity Epoch

    This is the [Aeternity](https://www.aeternity.com/) Epoch API.  # noqa: E501

    OpenAPI spec version: 1.0.0
    Contact: apiteam@aeternity.com
    Generated by: https://github.com/swagger-api/swagger-codegen.git
"""


import pprint
import re  # noqa: F401

import six


class BlockTimeSummary(object):
    """NOTE: This class is auto generated by the swagger code generator program.

    Do not edit the class manually.
    """

    """
    Attributes:
      swagger_types (dict): The key is attribute name
                            and the value is attribute type.
      attribute_map (dict): The key is attribute name
                            and the value is json key in definition.
    """
    swagger_types = {
        'height': 'int',
        'time': 'int',
        'time_delta_to_parent': 'int',
        'difficulty': 'float'
    }

    attribute_map = {
        'height': 'height',
        'time': 'time',
        'time_delta_to_parent': 'time_delta_to_parent',
        'difficulty': 'difficulty'
    }

    def __init__(self, height=None, time=None, time_delta_to_parent=None, difficulty=None):  # noqa: E501
        """BlockTimeSummary - a model defined in Swagger"""  # noqa: E501

        self._height = None
        self._time = None
        self._time_delta_to_parent = None
        self._difficulty = None
        self.discriminator = None

        if height is not None:
            self.height = height
        if time is not None:
            self.time = time
        if time_delta_to_parent is not None:
            self.time_delta_to_parent = time_delta_to_parent
        if difficulty is not None:
            self.difficulty = difficulty

    @property
    def height(self):
        """Gets the height of this BlockTimeSummary.  # noqa: E501


        :return: The height of this BlockTimeSummary.  # noqa: E501
        :rtype: int
        """
        return self._height

    @height.setter
    def height(self, height):
        """Sets the height of this BlockTimeSummary.


        :param height: The height of this BlockTimeSummary.  # noqa: E501
        :type: int
        """

        self._height = height

    @property
    def time(self):
        """Gets the time of this BlockTimeSummary.  # noqa: E501


        :return: The time of this BlockTimeSummary.  # noqa: E501
        :rtype: int
        """
        return self._time

    @time.setter
    def time(self, time):
        """Sets the time of this BlockTimeSummary.


        :param time: The time of this BlockTimeSummary.  # noqa: E501
        :type: int
        """

        self._time = time

    @property
    def time_delta_to_parent(self):
        """Gets the time_delta_to_parent of this BlockTimeSummary.  # noqa: E501


        :return: The time_delta_to_parent of this BlockTimeSummary.  # noqa: E501
        :rtype: int
        """
        return self._time_delta_to_parent

    @time_delta_to_parent.setter
    def time_delta_to_parent(self, time_delta_to_parent):
        """Sets the time_delta_to_parent of this BlockTimeSummary.


        :param time_delta_to_parent: The time_delta_to_parent of this BlockTimeSummary.  # noqa: E501
        :type: int
        """

        self._time_delta_to_parent = time_delta_to_parent

    @property
    def difficulty(self):
        """Gets the difficulty of this BlockTimeSummary.  # noqa: E501


        :return: The difficulty of this BlockTimeSummary.  # noqa: E501
        :rtype: float
        """
        return self._difficulty

    @difficulty.setter
    def difficulty(self, difficulty):
        """Sets the difficulty of this BlockTimeSummary.


        :param difficulty: The difficulty of this BlockTimeSummary.  # noqa: E501
        :type: float
        """

        self._difficulty = difficulty

    def to_dict(self):
        """Returns the model properties as a dict"""
        result = {}

        for attr, _ in six.iteritems(self.swagger_types):
            value = getattr(self, attr)
            if isinstance(value, list):
                result[attr] = list(map(
                    lambda x: x.to_dict() if hasattr(x, "to_dict") else x,
                    value
                ))
            elif hasattr(value, "to_dict"):
                result[attr] = value.to_dict()
            elif isinstance(value, dict):
                result[attr] = dict(map(
                    lambda item: (item[0], item[1].to_dict())
                    if hasattr(item[1], "to_dict") else item,
                    value.items()
                ))
            else:
                result[attr] = value

        return result

    def to_str(self):
        """Returns the string representation of the model"""
        return pprint.pformat(self.to_dict())

    def __repr__(self):
        """For `print` and `pprint`"""
        return self.to_str()

    def __eq__(self, other):
        """Returns true if both objects are equal"""
        if not isinstance(other, BlockTimeSummary):
            return False

        return self.__dict__ == other.__dict__

    def __ne__(self, other):
        """Returns true if both objects are not equal"""
        return not self == other
